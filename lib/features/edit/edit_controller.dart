/// 编辑控制器:持原图字节 + 预览帧,参数改动即时重算预览(小图,
/// 见 [decodeForEdit]);保存时 [renderFull] 把同一组归一化参数应用到
/// 原分辨率([applyEdit]),预览所见即所得。
///
/// 重活在子 isolate(即起即收,同帧分析/水印口径):引导解码
///([decodeForEdit] 原幅整解,高像素照片秒级,原构造器同步跑卡住
/// 首帧)、预览重渲染与裁剪底图(≤maxEdge 位图管线)。参数全部同步
/// 落(edited/frameSize/cropRect 即时可读,参数沿 notify 即发),渲染
/// 产物异步落(previewJpeg 沿再发一次 notify);连发只落最新一期
///(seq 闸,完成序不可控也不串图),dispose 后零投递。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../core/media/cube_lut.dart';
import '../../core/media/film_presets.dart';
import '../../core/media/image_edit.dart';

/// 子 isolate 渲染作业:预览位图 + 参数快照(纯值对象,复制传输)。
Uint8List? _renderJob((img.Image, PhotoEdit) args) {
  final (frame, edit) = args;
  return img.encodeJpg(applyEditToImage(frame, edit), quality: 90);
}

final class EditController extends ChangeNotifier {
  EditController({
    required Uint8List jpeg,
    this.maxPreviewEdge = 1600,
  }) : _original = jpeg {
    _bootstrap(jpeg);
  }

  /// 交互帧长边上限(小图上做裁剪/调节,保存时回原分辨率)。
  final int maxPreviewEdge;

  final Uint8List _original;

  /// 引导解码产物(异步落定;非 JPEG / 失败为 null)。
  img.Image? _previewFrame;

  final Completer<void> _ready = Completer<void>();
  bool _disposed = false;
  int _renderSeq = 0;
  Future<void>? _renderTask;

  Uint8List? _previewJpeg;
  int _rotationQuarter = 0;
  Rect? _cropRect;
  EditAdjustments _adjustments = const EditAdjustments();
  FilmPreset? _filmPreset;
  CubeLut? _lut;

  /// 底图解码失败(非 JPEG / 损坏 / 引导失败):页面按不可编辑处理。
  bool get isReady => _previewFrame != null;

  /// 引导进行中(解码 + 初始渲染未落定):页面显示引导态而非空态。
  bool get booting => !_ready.isCompleted;

  /// 引导完成(交互帧解码 + 初始预览渲染落定;非 JPEG 也算完成)。
  Future<void> get ready => _ready.future;

  /// 在途预览渲染排空(无在途即直返);测试同步点用。
  Future<void> get rendered => _renderTask ?? Future<void>.value();

  /// 当前渲染的预览 JPEG(null = 底图不可用或引导未完)。
  Uint8List? get previewJpeg => _previewJpeg;

  int get rotationQuarter => _rotationQuarter;
  Rect? get cropRect => _cropRect;
  EditAdjustments get adjustments => _adjustments;
  FilmPreset? get filmPreset => _filmPreset;
  CubeLut? get lut => _lut;

  PhotoEdit get edit => PhotoEdit(
        rotationQuarter: _rotationQuarter,
        cropRect: _cropRect,
        adjustments: _adjustments,
        filmPreset: _filmPreset,
        lut: _lut,
      );

  bool get edited => !edit.isNeutral;

  /// 引导:子 isolate 解交互帧 → 初始预览渲染 → ready 收口。
  Future<void> _bootstrap(Uint8List jpeg) async {
    img.Image? frame;
    try {
      // 闭包只捕获局部(jpeg/edge),不捕获 this(控制器不可跨 isolate)。
      final edge = maxPreviewEdge;
      frame = await Isolate.run(() => decodeForEdit(jpeg, maxEdge: edge));
    } on Object {
      frame = null; // isolate 传输级失败:按不可编辑处理(口径同解码失败)
    }
    if (_disposed) {
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    _previewFrame = frame;
    _notify(); // isReady/frameSize 沿(页面从引导态切换)
    await _renderPreview();
    if (!_ready.isCompleted) _ready.complete();
    _notify(); // ready 沿:引导收口(此时预览已在树上)
  }

  void rotateRight() {
    _rotationQuarter = (_rotationQuarter + 1) % 4;
    // 裁剪框随画面转(归一化坐标换轴),保留用户已选区域。
    final crop = _cropRect;
    if (crop != null) {
      _cropRect = rotateRectClockwise(crop);
    }
    _renderPreview();
  }

  void rotateLeft() {
    _rotationQuarter = (_rotationQuarter + 3) % 4;
    final crop = _cropRect;
    if (crop != null) {
      _cropRect = rotateRectCounterClockwise(crop);
    }
    _renderPreview();
  }

  /// 当前(旋转后)画幅尺寸 —— 裁剪 UI 的坐标基准。
  Size? get frameSize {
    final frame = _previewFrame;
    if (frame == null) return null;
    return _rotationQuarter % 2 == 1
        ? Size(frame.height.toDouble(), frame.width.toDouble())
        : Size(frame.width.toDouble(), frame.height.toDouble());
  }

  /// 裁剪模式的底图:应用当前调节/旋转/LUT 但不裁剪(框选所见即所得)。
  /// 子 isolate 渲染;失败(含传输级)回 null,页面以 Loading 兜底。
  Future<Uint8List?> renderCropBackdrop() async {
    final frame = _previewFrame;
    if (frame == null) return null;
    final edit = this.edit.copyWith(clearCrop: true);
    try {
      return await Isolate.run(() => _renderJob((frame, edit)));
    } on Object {
      return null;
    }
  }

  void setCrop(Rect? rect) {
    _cropRect = rect;
    _renderPreview();
  }

  void updateAdjustments(EditAdjustments value) {
    _adjustments = value;
    _renderPreview();
  }

  void setLut(CubeLut? value) {
    _lut = value;
    _renderPreview();
  }

  void setFilmPreset(FilmPreset? value) {
    _filmPreset = value;
    _renderPreview();
  }

  void reset() {
    _rotationQuarter = 0;
    _cropRect = null;
    _adjustments = const EditAdjustments();
    _filmPreset = null;
    _lut = null;
    _renderPreview();
  }

  /// 保存产物:原分辨率应用全部参数;未编辑 → 原字节直返。
  Uint8List renderFull() => applyEdit(_original, edit);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 参数沿:同步 notify(裁剪框/画幅/edited 即时上树),渲染异步排程。
  Future<void> _renderPreview() async {
    if (_disposed) return; // dispose 后零投递
    _notify();
    final seq = ++_renderSeq;
    final frame = _previewFrame;
    if (frame == null) {
      // 非 JPEG:无可渲染底图,预览恒空(口径同原同步路径)。
      _previewJpeg = null;
      _notify();
      return;
    }
    final edit = this.edit;
    final task = Isolate.run(() => _renderJob((frame, edit)));
    _renderTask = task;
    Uint8List? out;
    try {
      out = await task;
    } on Object {
      out = null; // 传输级失败:保持上次预览(口径同帧分析)
    }
    if (_disposed || seq != _renderSeq) return; // 迟到/被取代:弃
    if (out != null) _previewJpeg = out;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _renderSeq++; // 在途渲染迟到结果全部作废
    if (!_ready.isCompleted) _ready.complete(); // 引导等待方不悬挂
    super.dispose();
  }
}
