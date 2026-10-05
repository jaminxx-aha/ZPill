/// 编辑控制器(TODO §五 T4):持原图字节 + 预览帧,参数改动即时重算
/// 预览(小图,见 [decodeForEdit]);保存时 [renderFull] 把同一组
/// 归一化参数应用到原分辨率([applyEdit]),预览所见即所得。
library;

import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../core/media/cube_lut.dart';
import '../../core/media/image_edit.dart';

final class EditController extends ChangeNotifier {
  EditController({
    required Uint8List jpeg,
    this.maxPreviewEdge = 1600,
  })  : _original = jpeg,
        _previewFrame = decodeForEdit(jpeg, maxEdge: maxPreviewEdge) {
    _renderPreview();
  }

  /// 交互帧长边上限(小图上做裁剪/调节,保存时回原分辨率)。
  final int maxPreviewEdge;

  final Uint8List _original;
  final img.Image? _previewFrame;

  Uint8List? _previewJpeg;
  int _rotationQuarter = 0;
  Rect? _cropRect;
  EditAdjustments _adjustments = const EditAdjustments();
  CubeLut? _lut;

  /// 底图解码失败(非 JPEG / 损坏):页面按不可编辑处理。
  bool get isReady => _previewFrame != null;

  /// 当前渲染的预览 JPEG(null = 底图不可用)。
  Uint8List? get previewJpeg => _previewJpeg;

  int get rotationQuarter => _rotationQuarter;
  Rect? get cropRect => _cropRect;
  EditAdjustments get adjustments => _adjustments;
  CubeLut? get lut => _lut;

  PhotoEdit get edit => PhotoEdit(
        rotationQuarter: _rotationQuarter,
        cropRect: _cropRect,
        adjustments: _adjustments,
        lut: _lut,
      );

  bool get edited => !edit.isNeutral;

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
  Uint8List? renderCropBackdrop() {
    final frame = _previewFrame;
    if (frame == null) return null;
    final out = applyEditToImage(frame, edit.copyWith(clearCrop: true));
    return img.encodeJpg(out, quality: 90);
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

  void reset() {
    _rotationQuarter = 0;
    _cropRect = null;
    _adjustments = const EditAdjustments();
    _lut = null;
    _renderPreview();
  }

  /// 保存产物:原分辨率应用全部参数;未编辑 → 原字节直返。
  Uint8List renderFull() => applyEdit(_original, edit);

  void _renderPreview() {
    final frame = _previewFrame;
    if (frame == null) {
      _previewJpeg = null;
      notifyListeners();
      return;
    }
    final out = applyEditToImage(frame, edit);
    _previewJpeg = img.encodeJpg(out, quality: 90);
    notifyListeners();
  }
}
