/// 编辑页(TODO §五 T4):预览 + 四工具(旋转/裁剪/调节/LUT)+ 相册保存。
///
/// 交互模型:参数改动的重算都在预览小图上(见 [EditController]);
/// 保存时 [compute] 把参数应用到原分辨率(重编码秒级,勿卡 UI)。
/// 裁剪是独立模式:底图铺满 + 遮罩 + 角/边手柄,确认才落到参数。
/// LUT 面板含内置风格 + 剪贴板导入 .cube/.xmp 文本(.cube 为 SpeedGrade
/// 表;.xmp 为 Adobe 相机配置 RGBTable,见 core/media/xmp_rgb_table;
/// 受系统剪贴板容量限制,偏大 LUT 建议先缩到 17³)。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../../core/media/cube_lut.dart';
import '../../core/media/image_edit.dart';
import '../../core/media/xmp_rgb_table.dart' show looksLikeXmp, parseXmpRgbTable;
import '../../core/ptpip/object_format.dart' show ObjectKind;
import '../../core/transfer/object_downloader.dart' show ObjectDownloader;
import '../../design/app_colors.dart';
import '../../l10n/l10n.dart';
import '../../platform/gallery_saver.dart';
import '../../platform/services.dart';
import 'edit_controller.dart';
import 'lut_presets.dart';

enum _Tool { rotate, crop, adjust, lut }

Uint8List _renderFullJob((Uint8List, PhotoEdit) args) =>
    applyEdit(args.$1, args.$2);

class EditPage extends StatefulWidget {
  const EditPage({
    super.key,
    required this.jpeg,
    required this.filename,
    this.gallery,
  });

  final Uint8List jpeg;
  final String filename;

  /// 测试注入;缺省平台相册通道。
  final GallerySaver? gallery;

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final EditController _controller;
  _Tool _tool = _Tool.rotate;
  CubeLut? _importedLut;
  bool _saving = false;

  // 裁剪模式工作区(未确认前不进控制器)。
  bool _cropping = false;
  Rect? _workingCrop;
  double? _aspect; // null = 自由;-1 = 原比例(随画面纵横比)
  Uint8List? _cropBackdrop;

  // 滑条本地值:拖动期只动滑条,松手才重算预览(连续重算太重)。
  late double _brightness, _contrast, _saturation, _warmth;

  @override
  void initState() {
    super.initState();
    _controller = EditController(jpeg: widget.jpeg);
    final a = _controller.adjustments;
    _brightness = a.brightness;
    _contrast = a.contrast;
    _saturation = a.saturation;
    _warmth = a.warmth;
  }

  GallerySaver get _gallery => widget.gallery ?? PlatformServices.gallery;

  Future<void> _save() async {
    if (_saving || !_controller.edited) return;
    setState(() => _saving = true);
    try {
      final bytes =
          await compute(_renderFullJob, (widget.jpeg, _controller.edit));
      final gallery = _gallery;
      final dir = await gallery.tempDir();
      final dot = widget.filename.lastIndexOf('.');
      final stem =
          dot > 0 ? widget.filename.substring(0, dot) : widget.filename;
      final outName = '${stem}_edit.jpg';
      final path = await ObjectDownloader.uniquePath(Directory(dir), outName);
      await File(path).writeAsBytes(bytes);
      var saved = false;
      try {
        final uris = await gallery.importFiles([
          GalleryImportRequest(
              path: path, kind: ObjectKind.image, filename: outName),
        ]);
        saved = uris.isNotEmpty;
      } finally {
        // 导入成功/取消都删临时文件(相册已有副本或用户放弃)。
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } on FileSystemException {
          // 清理失败不影响结果反馈
        }
      }
      if (!mounted) return;
      _toast(saved ? '已保存到相册' : '未保存(已取消)');
    } on Exception {
      if (!mounted) return;
      _toast('保存失败,请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _enterCropMode() {
    setState(() {
      _tool = _Tool.crop;
      _cropping = true;
      _workingCrop =
          _controller.cropRect ?? const Rect.fromLTRB(0.05, 0.05, 0.95, 0.95);
      _cropBackdrop = _controller.renderCropBackdrop();
    });
  }

  void _exitCrop() {
    setState(() {
      _cropping = false;
      _cropBackdrop = null;
    });
  }

  void _applyCrop() {
    final r = _workingCrop;
    // 全幅(边距 <1%)视为不裁:省一次无谓的重编码。
    final isFull = r == null ||
        (r.left <= 0.01 &&
            r.top <= 0.01 &&
            r.right >= 0.99 &&
            r.bottom >= 0.99);
    _controller.setCrop(isFull ? null : r);
    _exitCrop();
  }

  void _setAspect(double? aspect) {
    final frame = _controller.frameSize;
    final a = aspect == -1
        ? (frame == null ? null : frame.width / frame.height)
        : aspect;
    var r = _workingCrop ?? const Rect.fromLTRB(0.05, 0.05, 0.95, 0.95);
    if (a != null && a > 0) {
      // 以当前中心为准,该比例的最大可容纳矩形。
      var w = 1.0, h = w / a;
      if (h > 1) {
        h = 1;
        w = a;
      }
      final c = r.center;
      r = Rect.fromLTWH((c.dx - w / 2).clamp(0.0, 1 - w),
          (c.dy - h / 2).clamp(0.0, 1 - h), w, h);
    }
    setState(() {
      _aspect = aspect;
      _workingCrop = r;
    });
  }

  Future<void> _importLutFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    // await 后用 context(未命名兜底/带参模板),mounted 守卫同 _save。
    if (!mounted) return;
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      _toast('剪贴板没有文本');
      return;
    }
    try {
      // 同一剪贴板入口分派:XMP 标记(rdf:Description 等)走 RGBTable
      // 解码链,否则按 .cube 文本解析;两类失败都抛 FormatException。
      final lut = looksLikeXmp(text)
          ? parseXmpRgbTable(text).toCubeLut()
          : CubeLut.parse(text);
      setState(() => _importedLut = lut);
      _controller.setLut(lut);
      final title = lut.title.isEmpty ? context.t('未命名') : lut.title;
      // 带参模板在调用点先 t+填充;_toast 内的二次 t 对已填充串不命中
      // 键、原样回落(双重包裹无害,i18n-7 在案)。
      _toast(context
          .t('已导入「{title}」({size}³)', {'title': title, 'size': lut.size}));
    } on FormatException catch (e) {
      _toast(context.t('导入失败:{e}', {'e': e.message}));
    }
  }

  /// await 后的消费点收口:静态键原文直传,由这里统一 t;带参模板在
  /// 调用点已 t+填充,二次 t 不命中键原样回落(无害)。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.t(message))));
  }

  @override
  Widget build(BuildContext context) {
    // 整页订阅控制器:保存/重置按钮的可用性随 edited 变化,不能只让
    // 预览区刷新(旋转/LUT 走 notifyListeners,不触发本 State 的 setState)。
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => Scaffold(
        backgroundColor: AppMedia.background,
        appBar: AppBar(
          backgroundColor: AppMedia.chrome,
          foregroundColor: AppMedia.onMedia,
          title: Text(widget.filename, style: const TextStyle(fontSize: 16)),
          actions: [
            IconButton(
              tooltip: context.t('重置'),
              onPressed: _controller.edited ? _reset : null,
              icon: const Icon(Icons.restart_alt),
            ),
            IconButton(
              tooltip: context.t('保存到相册'),
              onPressed: (_controller.edited && !_saving) ? _save : null,
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppMedia.onMedia),
                    )
                  : const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: !_controller.isReady
            ? Center(
                child: Text(context.t('无法编辑此文件(仅支持 JPEG)'),
                    style: const TextStyle(color: AppMedia.onMediaMuted)),
              )
            : Column(
                children: [
                  Expanded(child: _previewArea()),
                  _toolBar(),
                ],
              ),
      ),
    );
  }

  void _reset() {
    _controller.reset();
    setState(() {
      final a = _controller.adjustments;
      _brightness = a.brightness;
      _contrast = a.contrast;
      _saturation = a.saturation;
      _warmth = a.warmth;
      _cropping = false;
      _cropBackdrop = null;
    });
  }

  Widget _previewArea() {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        if (_cropping) {
          final backdrop = _cropBackdrop;
          final frame = _controller.frameSize;
          if (backdrop == null || frame == null) {
            return const Center(
                child: CircularProgressIndicator(color: AppMedia.onMedia));
          }
          return CropView(
            backdrop: backdrop,
            frameSize: frame,
            rect: _workingCrop ?? const Rect.fromLTRB(0.05, 0.05, 0.95, 0.95),
            aspect: _aspect == -1 ? (frame.width / frame.height) : _aspect,
            onChanged: (r) => setState(() => _workingCrop = r),
          );
        }
        final preview = _controller.previewJpeg;
        if (preview == null) {
          return const Center(
              child: CircularProgressIndicator(color: AppMedia.onMedia));
        }
        return InteractiveViewer(
          maxScale: 8,
          child: Center(child: Image.memory(preview, fit: BoxFit.contain)),
        );
      },
    );
  }

  Widget _toolBar() {
    return SafeArea(
      top: false,
      child: Material(
        color: AppMedia.chrome,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  for (final t in _Tool.values)
                    Expanded(
                      child: IconButton(
                        color: (t == _tool || (t == _Tool.crop && _cropping))
                            ? AppMedia.onMedia
                            : AppMedia.onMediaFaint,
                        onPressed: () => t == _Tool.crop && !_cropping
                            ? _enterCropMode()
                            : _selectTool(t),
                        icon: Icon(switch (t) {
                          _Tool.rotate => Icons.rotate_right_outlined,
                          _Tool.crop => Icons.crop,
                          _Tool.adjust => Icons.tune,
                          _Tool.lut => Icons.palette_outlined,
                        }),
                        tooltip: switch (t) {
                          _Tool.rotate => context.t('旋转'),
                          _Tool.crop => context.t('裁剪'),
                          _Tool.adjust => context.t('调节'),
                          _Tool.lut => 'LUT',
                        },
                      ),
                    ),
                ],
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: _cropping
                  ? _cropPanel()
                  : SizedBox(
                      key: ValueKey(_tool),
                      height: 168,
                      child: switch (_tool) {
                        _Tool.rotate => _rotatePanel(),
                        _Tool.crop => _cropEntryPanel(),
                        _Tool.adjust => _adjustPanel(),
                        _Tool.lut => _lutPanel(),
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectTool(_Tool t) {
    setState(() {
      _cropping = false;
      _cropBackdrop = null;
      _tool = t;
    });
  }

  Widget _rotatePanel() {
    Widget button({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) =>
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: AppMedia.onMedia),
          onPressed: onTap,
          icon: Icon(icon),
          // label 原文即键,显示点包 t(调用点传中文原文字面量)。
          label: Text(context.t(label)),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          button(
              icon: Icons.rotate_left_outlined,
              label: '左转 90°',
              onTap: _controller.rotateLeft),
          button(
              icon: Icons.rotate_right_outlined,
              label: '右转 90°',
              onTap: _controller.rotateRight),
        ],
      ),
    );
  }

  Widget _cropEntryPanel() {
    return Center(
      child: FilledButton.icon(
        onPressed: _enterCropMode,
        icon: const Icon(Icons.crop),
        label: Text(context.t('选择裁剪区域')),
      ),
    );
  }

  Widget _cropPanel() {
    final aspects = <(double?, String)>[
      (null, '自由'),
      (1.0, '1:1'),
      (4 / 3, '4:3'),
      (3 / 4, '3:4'),
      (16 / 9, '16:9'),
      (9 / 16, '9:16'),
    ];
    return SizedBox(
      key: const ValueKey('crop-panel'),
      height: 168,
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final (a, label) in aspects)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      // 「自由」入目录;1:1 等纯比例串未命中原文直返。
                      label: Text(context.t(label)),
                      selected: _aspect == a,
                      onSelected: (_) => _setAspect(a),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(context.t('原比例')),
                    selected: _aspect == -1,
                    onSelected: (_) => _setAspect(-1),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: AppMedia.onMediaMuted),
                  onPressed: _exitCrop,
                  child: Text(context.t('取消')),
                ),
                // 「应用」是 Apply 动词(i18n-6 预留的决定:browser 段的
                // 「到应用/下载到应用」是名词性介词片段,不同键不撞义)。
                FilledButton(
                    onPressed: _applyCrop, child: Text(context.t('应用'))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _adjustPanel() {
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      String Function(double) fmt,
      ValueChanged<double> setLocal,
      ValueChanged<double> onEnd,
    ) =>
        Row(
          children: [
            SizedBox(
                width: 52,
                // label 原文即键,显示点包 t(调用点传中文原文字面量)。
                child: Text(context.t(label),
                    style: const TextStyle(
                        color: AppMedia.onMediaMuted, fontSize: 13))),
            Expanded(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: 20,
                label: fmt(value),
                onChanged: (v) => setState(() => setLocal(v)),
                onChangeEnd: onEnd,
              ),
            ),
            SizedBox(
                width: 48,
                child: Text(fmt(value),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        color: AppMedia.onMediaFaint, fontSize: 12))),
          ],
        );

    void push() {
      _controller.updateAdjustments(EditAdjustments(
        brightness: _brightness,
        contrast: _contrast,
        saturation: _saturation,
        warmth: _warmth,
      ));
    }

    String pct(double v) => '${(v * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          slider('亮度', _brightness, 0.5, 1.5, pct, (v) => _brightness = v,
              (_) => push()),
          slider('对比', _contrast, 0.5, 1.5, pct, (v) => _contrast = v,
              (_) => push()),
          slider('饱和', _saturation, 0, 2, pct, (v) => _saturation = v,
              (_) => push()),
          slider('暖调', _warmth, -1, 1, (v) => v.toStringAsFixed(1),
              (v) => _warmth = v, (_) => push()),
        ],
      ),
    );
  }

  Widget _lutPanel() {
    final luts = <(String, CubeLut?)>[
      ('无', null),
      for (final l in builtinLuts) (l.title, l),
      if (_importedLut != null)
        (
          _importedLut!.title.isEmpty ? '导入' : _importedLut!.title,
          _importedLut
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final (name, lut) in luts)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      // LUT 标题键存 edit/lut_presets 的 builtinLuts
                      // (4 条已按 i18n-3 先例在 i18n-4 入目录,remote_
                      // settings_panel 同款显示点包 t);「无/导入」与剪贴板
                      // 导入的 .cube TITLE/.xmp 表名(通常拉丁)未命中原样
                      // 回落。
                      label: Text(context.t(name)),
                      selected: _controller.lut == lut,
                      onSelected: (_) => _controller.setLut(lut),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppMedia.onMedia),
            onPressed: _importLutFromClipboard,
            icon: const Icon(Icons.content_paste),
            label: Text(context.t('从剪贴板导入 .cube/.xmp')),
          ),
        ],
      ),
    );
  }
}

/// 裁剪视图:底图 contain 铺底 + 半透遮罩 + 白框网格 + 角/边手柄拖拽。
/// 矩形归一化(0..1,旋转后坐标系),[aspect] 非空时锁定输出宽高比。
class CropView extends StatefulWidget {
  const CropView({
    super.key,
    required this.backdrop,
    required this.frameSize,
    required this.rect,
    this.aspect,
    required this.onChanged,
  });

  final Uint8List backdrop;
  final Size frameSize;
  final Rect rect;
  final double? aspect;
  final ValueChanged<Rect> onChanged;

  @override
  State<CropView> createState() => _CropViewState();
}

enum _Handle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right,
  move,
}

class _CropViewState extends State<CropView> {
  _Handle? _drag;
  late Rect _startRect;
  late Offset _moveAnchor; // 拖整体时的抓取点(归一化,相对矩形)

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = _fittedRect(constraints.biggest);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: fitted,
              child: Image.memory(widget.backdrop, fit: BoxFit.fill),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _CropPainter(fitted: fitted, rect: widget.rect),
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) {
                  _startRect = widget.rect;
                  _drag = _hitHandle(fitted, d.localPosition);
                  if (_drag == _Handle.move) {
                    final nx =
                        (d.localPosition.dx - fitted.left) / fitted.width;
                    final ny =
                        (d.localPosition.dy - fitted.top) / fitted.height;
                    _moveAnchor = Offset(
                      ((nx - _startRect.left) / _startRect.width)
                          .clamp(0.0, 1.0),
                      ((ny - _startRect.top) / _startRect.height)
                          .clamp(0.0, 1.0),
                    );
                  }
                },
                onPanUpdate: (d) {
                  if (_drag != null) {
                    widget
                        .onChanged(_applyDrag(fitted, _drag!, d.localPosition));
                  }
                },
                onPanEnd: (_) => _drag = null,
                onPanCancel: () => _drag = null,
              ),
            ),
          ],
        );
      },
    );
  }

  /// contain 布局:预览帧在可用区域内的实际位置。
  Rect _fittedRect(Size area) {
    final scale = math.min(area.width / widget.frameSize.width,
        area.height / widget.frameSize.height);
    final size = widget.frameSize * scale;
    return Offset(
            (area.width - size.width) / 2, (area.height - size.height) / 2) &
        size;
  }

  /// 手柄命中测试(屏幕坐标;24px 触达半径,角/边优先于整体移动)。
  _Handle? _hitHandle(Rect fitted, Offset p) {
    final r = widget.rect;
    Offset corner(double nx, double ny) =>
        fitted.topLeft + Offset(nx * fitted.width, ny * fitted.height);
    const touch = 24.0;
    _Handle? nearest;
    var best = touch;
    void probe(_Handle h, Offset c) {
      final d = (p - c).distance;
      if (d <= best) {
        best = d;
        nearest = h;
      }
    }

    probe(_Handle.topLeft, corner(r.left, r.top));
    probe(_Handle.topRight, corner(r.right, r.top));
    probe(_Handle.bottomLeft, corner(r.left, r.bottom));
    probe(_Handle.bottomRight, corner(r.right, r.bottom));
    if (nearest != null) return nearest;

    final tl = corner(r.left, r.top), br = corner(r.right, r.bottom);
    double distToSeg(Offset a, Offset b) {
      final ab = b - a;
      final ap = p - a;
      final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / ab.distanceSquared)
          .clamp(0.0, 1.0);
      return (p - (a + ab * t)).distance;
    }

    if (distToSeg(tl, Offset(br.dx, tl.dy)) <= touch) return _Handle.top;
    if (distToSeg(Offset(tl.dx, br.dy), br) <= touch) return _Handle.bottom;
    if (distToSeg(tl, Offset(tl.dx, br.dy)) <= touch) return _Handle.left;
    if (distToSeg(Offset(br.dx, tl.dy), br) <= touch) return _Handle.right;

    return Rect.fromLTRB(tl.dx, tl.dy, br.dx, br.dy).contains(p)
        ? _Handle.move
        : null;
  }

  /// 拖拽应用:手柄决定哪条边动;比例锁定时对角/对边联动;最小 5%。
  Rect _applyDrag(Rect fitted, _Handle h, Offset p) {
    final nx = ((p.dx - fitted.left) / fitted.width).clamp(0.0, 1.0);
    final ny = ((p.dy - fitted.top) / fitted.height).clamp(0.0, 1.0);
    var r = _startRect;
    const minSize = 0.05;

    if (h == _Handle.move) {
      final w = r.width, hh = r.height;
      return Rect.fromLTWH((nx - _moveAnchor.dx * w).clamp(0.0, 1 - w),
          (ny - _moveAnchor.dy * hh).clamp(0.0, 1 - hh), w, hh);
    }
    switch (h) {
      case _Handle.topLeft:
        r = Rect.fromLTRB(nx, ny, r.right, r.bottom);
      case _Handle.topRight:
        r = Rect.fromLTRB(r.left, ny, nx, r.bottom);
      case _Handle.bottomLeft:
        r = Rect.fromLTRB(nx, r.top, r.right, ny);
      case _Handle.bottomRight:
        r = Rect.fromLTRB(r.left, r.top, nx, ny);
      case _Handle.top:
        r = Rect.fromLTRB(r.left, ny, r.right, r.bottom);
      case _Handle.bottom:
        r = Rect.fromLTRB(r.left, r.top, r.right, ny);
      case _Handle.left:
        r = Rect.fromLTRB(nx, r.top, r.right, r.bottom);
      case _Handle.right:
        r = Rect.fromLTRB(r.left, r.top, nx, r.bottom);
      case _Handle.move:
        break;
    }

    if (widget.aspect != null) {
      r = _enforceAspect(r, h, widget.aspect!, minSize);
    }

    // 最小尺寸与边界钳制(拖动侧让位,固定侧不动)。
    var left = r.left, top = r.top, right = r.right, bottom = r.bottom;
    if (right - left < minSize) {
      if (h == _Handle.left ||
          h == _Handle.topLeft ||
          h == _Handle.bottomLeft) {
        left = right - minSize;
      } else {
        right = left + minSize;
      }
    }
    if (bottom - top < minSize) {
      if (h == _Handle.top || h == _Handle.topLeft || h == _Handle.topRight) {
        top = bottom - minSize;
      } else {
        bottom = top + minSize;
      }
    }
    return Rect.fromLTRB(left.clamp(0, 1 - minSize), top.clamp(0, 1 - minSize),
        right.clamp(minSize, 1), bottom.clamp(minSize, 1));
  }

  /// 比例锁定下重解矩形:角手柄锚定对角,横边手柄定高回推宽,竖边反之。
  Rect _enforceAspect(Rect r, _Handle h, double aspect, double minSize) {
    double l = r.left, t = r.top, rr = r.right, b = r.bottom;
    switch (h) {
      case _Handle.topLeft:
        final nw = ((b - t) * aspect).clamp(minSize, rr);
        l = rr - nw;
        t = b - nw / aspect;
      case _Handle.topRight:
        final nw = ((b - t) * aspect).clamp(minSize, 1 - l);
        rr = l + nw;
        t = b - nw / aspect;
      case _Handle.bottomLeft:
        final nw = ((b - t) * aspect).clamp(minSize, rr);
        l = rr - nw;
        b = t + nw / aspect;
      case _Handle.bottomRight:
        final nw = ((b - t) * aspect).clamp(minSize, 1 - l);
        rr = l + nw;
        b = t + nw / aspect;
      case _Handle.top:
      case _Handle.bottom:
        final nh = (b - t).clamp(minSize, 1.0);
        final nw = nh * aspect;
        if (nw <= 1) {
          final cx = (l + rr) / 2;
          l = (cx - nw / 2).clamp(0.0, 1 - nw);
          rr = l + nw;
          if (h == _Handle.top) {
            t = b - nh;
          } else {
            b = t + nh;
          }
        }
      case _Handle.left:
      case _Handle.right:
        final nw = (rr - l).clamp(minSize, 1.0);
        final nh = nw / aspect;
        if (nh <= 1) {
          final cy = (t + b) / 2;
          t = (cy - nh / 2).clamp(0.0, 1 - nh);
          b = t + nh;
          if (h == _Handle.left) {
            l = rr - nw;
          } else {
            rr = l + nw;
          }
        }
      case _Handle.move:
        break;
    }
    return Rect.fromLTRB(l, t, rr, b);
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({required this.fitted, required this.rect});

  final Rect fitted;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final crop = Rect.fromLTRB(
      fitted.left + rect.left * fitted.width,
      fitted.top + rect.top * fitted.height,
      fitted.left + rect.right * fitted.width,
      fitted.top + rect.bottom * fitted.height,
    );
    // 遮罩:全幅半透黑,裁剪区内清透(露出底图)。
    canvas.drawRect(Offset.zero & size,
        Paint()..color = AppMedia.background.withValues(alpha: 0.54));
    canvas.save();
    canvas.clipRect(crop);
    canvas.drawRect(crop, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppMedia.onMedia;
    canvas.drawRect(crop, border);
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = AppMedia.onMediaSubtle;
    for (var i = 1; i < 3; i++) {
      final x = crop.left + crop.width * i / 3;
      final y = crop.top + crop.height * i / 3;
      canvas.drawLine(Offset(x, crop.top), Offset(x, crop.bottom), grid);
      canvas.drawLine(Offset(crop.left, y), Offset(crop.right, y), grid);
    }
    final handle = Paint()..color = AppMedia.onMedia;
    for (final c in [
      crop.topLeft,
      crop.topRight,
      crop.bottomLeft,
      crop.bottomRight,
    ]) {
      canvas.drawRect(Rect.fromCircle(center: c, radius: 4), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.fitted != fitted || old.rect != rect;
}
