/// 设置仓库(TODO.md §五 P2/P3):[AppSettings] 模型 + 文件/内存实现。
///
/// 持久化走 JSON 文件(`<dataDir>/settings.json`,全量写回 + 内存缓存),
/// 与配对档案同款;T4 的水印/LUT 等字段后续在 [AppSettings] 上扩。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/browser/photo_group.dart';

enum TransferQuality { original, compressed }

/// 水印模板(TODO §五 T4):off 关闭;corner 角标;card 摄影卡片。
enum WatermarkStyle { off, corner, card }

/// 深浅模式(system = 跟随系统;light/dark = 锁定)。独立于 Material
/// 的 ThemeMode 枚举 —— data 层不依赖 Flutter,app 根再做映射。
enum AppThemeMode { system, light, dark }

/// 取景画面上采样档(OpenZCine FeedUpscaler 口径,AI 档未引 ——
/// 无 CoreML 接线,不虚设):off = 现状(低质采样);fast = Flutter
/// 内建 cubic(FilterQuality.high,零额外开销);quality = 片元着色器
/// (Catmull-Rom 上采样 + 锐化,可叠时域降噪)。
enum FeedUpscaler { off, fast, quality }

/// 变宽还原(anamorphic de-squeeze)倍率预设:1.0 = 关。OpenZCine
/// 口径 1.6× 为常用预设;自定义 1.00–2.00(0.01 步进)在设置页滑杆。
const kDeSqueezePresets = [1.0, 1.3, 1.5, 1.6, 2.0];

final class AppSettings {
  const AppSettings({
    this.autoTransfer = false,
    this.autoTransferFormat = PhotoDownloadFormat.both,
    this.quality = TransferQuality.original,
    this.batterySaver = false,
    this.customSavePath,
    this.themeMode = AppThemeMode.system,
    this.xmpCreator,
    this.xmpRights,
    this.xmpInjectRating = false,
    this.xmpInjectGps = false,
    this.watermarkStyle = WatermarkStyle.off,
    this.watermarkText,
    this.feedUpscaler = FeedUpscaler.off,
    this.temporalDenoise = false,
    this.autoRotateFeed = true,
    this.deSqueeze = 1.0,
    this.monitorGrid = false,
    this.monitorZebra = false,
    this.monitorHistogram = false,
    this.monitorLevel = false,
    this.monitorFalseColor = false,
    this.monitorPeaking = false,
    this.monitorFocusDial = false,
    this.liveViewOn = true,
    this.liveViewImageSize = 3,
    this.liveViewImageCompression = 5,
    this.sdramCapture = false,
  });

  final bool autoTransfer;

  /// 速传(ObjectAdded 自动下载)的格式过滤:双格式照片组按此选文件。
  final PhotoDownloadFormat autoTransferFormat;

  final TransferQuality quality; // P3:传输质量(压缩路径未实现,暂不消费)
  final bool batterySaver; // P3:省电模式(未消费)
  final String? customSavePath; // P3:自定义存储路径(未消费)

  /// 深浅模式:默认跟随系统,设置页可锁定。
  final AppThemeMode themeMode;

  /// XMP 元数据注入(TODO §四):作者(dc:creator),空 = 不写该字段。
  final String? xmpCreator;

  /// 版权声明(dc:rights),空 = 不写该字段。
  final String? xmpRights;

  /// 下载 JPG 时把本地评分写入 xmp:Rating。
  final bool xmpInjectRating;

  /// 下载 JPG 时把当前位置写入 EXIF GPS(经 nikonpill/location 通道)。
  final bool xmpInjectGps;

  /// 下载 JPG 合成水印(TODO §五 T4):模板选择,off = 不合成。
  final WatermarkStyle watermarkStyle;

  /// 水印文本:角标 = 水印字样(空 = 相机型号);卡片 = 追加落款。
  final String? watermarkText;

  /// 取景画面上采样档(默认关 = 现状路径)。
  final FeedUpscaler feedUpscaler;

  /// 时域降噪(前后帧运动自适应混合;仅 [FeedUpscaler.quality] 档
  /// 生效 —— 着色器管线才有前帧采样器)。
  final bool temporalDenoise;

  /// 画面自动旋转(默认开):相机竖持/倒置时按帧头 @839 把画面转正
  /// 显示(纯显示层,不动帧数据)。
  final bool autoRotateFeed;

  /// 变宽还原倍率(1.0 = 关;显示层水平拉伸,拍照/视频/查看器同源)。
  final double deSqueeze;

  /// 监看开关组(2026-10-12 十二轮持久化:网格/斑马纹/直方图/水平仪/
  /// 伪色/峰值/拉焦轮):页面侧 [MonitorToggles] 经桥接函数拆装
  /// (features/remote/monitor_toggles.dart)。
  final bool monitorGrid;
  final bool monitorZebra;
  final bool monitorHistogram;
  final bool monitorLevel;
  final bool monitorFalseColor;
  final bool monitorPeaking;
  final bool monitorFocusDial;

  /// 取景总开关(十二轮「取景器关闭的开关」):默认开 = 「取景默认
  /// 打开」原定案;持久关 = 进页/回台/连接沿都不自动起景,拍摄设置
  /// 浮层「取景」钮再开。
  final bool liveViewOn;

  /// 取景画质档(2026-10-12 官方 §6.5.11.4-5):null = 跟随相机(不写
  /// 机身);非 null = 连接沿/改动沿写 0xD1AC/0xD1BC(尺寸 1=QVGA/
  /// 2=VGA/3=XGA;压缩 0=Basic 尺寸优先…5=Fine 质量优先)。默认 XGA/
  /// Fine(2026-10-13:出厂默认档全屏放大约 3 倍发糊,SnapBridge 同款
  /// 定档;「跟随相机」降级为显式选项 —— 旧档无键仍回落 null)。
  final int? liveViewImageSize;
  final int? liveViewImageCompression;

  /// SDRAM 直拍(0x90CB AF+SDRAM 一体拍):开 = 快门改发一体拍并把
  /// 0xC101 回传对象收进图库(不入卡);关 = 常规快门 0x2019/0x9207。
  final bool sdramCapture;

  /// copyWith 的「未传」哨兵:画质两字段要能把 null(跟随相机)写回,
  /// `??` 模式做不到 —— 传值(含显式 null)即覆盖,不传保持原值。
  static const Object _unset = Object();

  AppSettings copyWith({
    bool? autoTransfer,
    PhotoDownloadFormat? autoTransferFormat,
    TransferQuality? quality,
    bool? batterySaver,
    String? customSavePath,
    AppThemeMode? themeMode,
    String? xmpCreator,
    String? xmpRights,
    bool? xmpInjectRating,
    bool? xmpInjectGps,
    WatermarkStyle? watermarkStyle,
    String? watermarkText,
    FeedUpscaler? feedUpscaler,
    bool? temporalDenoise,
    bool? autoRotateFeed,
    double? deSqueeze,
    bool? monitorGrid,
    bool? monitorZebra,
    bool? monitorHistogram,
    bool? monitorLevel,
    bool? monitorFalseColor,
    bool? monitorPeaking,
    bool? monitorFocusDial,
    bool? liveViewOn,
    Object? liveViewImageSize = _unset,
    Object? liveViewImageCompression = _unset,
    bool? sdramCapture,
  }) =>
      AppSettings(
        autoTransfer: autoTransfer ?? this.autoTransfer,
        autoTransferFormat: autoTransferFormat ?? this.autoTransferFormat,
        quality: quality ?? this.quality,
        batterySaver: batterySaver ?? this.batterySaver,
        customSavePath: customSavePath ?? this.customSavePath,
        themeMode: themeMode ?? this.themeMode,
        xmpCreator: xmpCreator ?? this.xmpCreator,
        xmpRights: xmpRights ?? this.xmpRights,
        xmpInjectRating: xmpInjectRating ?? this.xmpInjectRating,
        xmpInjectGps: xmpInjectGps ?? this.xmpInjectGps,
        watermarkStyle: watermarkStyle ?? this.watermarkStyle,
        watermarkText: watermarkText ?? this.watermarkText,
        feedUpscaler: feedUpscaler ?? this.feedUpscaler,
        temporalDenoise: temporalDenoise ?? this.temporalDenoise,
        autoRotateFeed: autoRotateFeed ?? this.autoRotateFeed,
        deSqueeze: deSqueeze ?? this.deSqueeze,
        monitorGrid: monitorGrid ?? this.monitorGrid,
        monitorZebra: monitorZebra ?? this.monitorZebra,
        monitorHistogram: monitorHistogram ?? this.monitorHistogram,
        monitorLevel: monitorLevel ?? this.monitorLevel,
        monitorFalseColor: monitorFalseColor ?? this.monitorFalseColor,
        monitorPeaking: monitorPeaking ?? this.monitorPeaking,
        monitorFocusDial: monitorFocusDial ?? this.monitorFocusDial,
        liveViewOn: liveViewOn ?? this.liveViewOn,
        liveViewImageSize: liveViewImageSize == _unset
            ? this.liveViewImageSize
            : liveViewImageSize as int?,
        liveViewImageCompression: liveViewImageCompression == _unset
            ? this.liveViewImageCompression
            : liveViewImageCompression as int?,
        sdramCapture: sdramCapture ?? this.sdramCapture,
      );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.autoTransfer == autoTransfer &&
      other.autoTransferFormat == autoTransferFormat &&
      other.quality == quality &&
      other.batterySaver == batterySaver &&
      other.customSavePath == customSavePath &&
      other.themeMode == themeMode &&
      other.xmpCreator == xmpCreator &&
      other.xmpRights == xmpRights &&
      other.xmpInjectRating == xmpInjectRating &&
      other.xmpInjectGps == xmpInjectGps &&
      other.watermarkStyle == watermarkStyle &&
      other.watermarkText == watermarkText &&
      other.feedUpscaler == feedUpscaler &&
      other.temporalDenoise == temporalDenoise &&
      other.autoRotateFeed == autoRotateFeed &&
      other.deSqueeze == deSqueeze &&
      other.monitorGrid == monitorGrid &&
      other.monitorZebra == monitorZebra &&
      other.monitorHistogram == monitorHistogram &&
      other.monitorLevel == monitorLevel &&
      other.monitorFalseColor == monitorFalseColor &&
      other.monitorPeaking == monitorPeaking &&
      other.monitorFocusDial == monitorFocusDial &&
      other.liveViewOn == liveViewOn &&
      other.liveViewImageSize == liveViewImageSize &&
      other.liveViewImageCompression == liveViewImageCompression &&
      other.sdramCapture == sdramCapture;

  @override
  // Object.hash 位置参上限 20,字段 24 个 → hashAll(列表序即上面 == 序)。
  int get hashCode => Object.hashAll([
        autoTransfer, autoTransferFormat, quality, batterySaver, customSavePath,
        themeMode, xmpCreator, xmpRights, xmpInjectRating, xmpInjectGps,
        watermarkStyle, watermarkText, feedUpscaler, temporalDenoise,
        autoRotateFeed, deSqueeze,
        monitorGrid, monitorZebra, monitorHistogram, monitorLevel,
        monitorFalseColor, monitorPeaking, monitorFocusDial, liveViewOn,
        liveViewImageSize, liveViewImageCompression, sdramCapture,
      ]);

  Map<String, Object?> toJson() => {
        'autoTransfer': autoTransfer,
        'autoTransferFormat': autoTransferFormat.name,
        'quality': quality.name,
        'batterySaver': batterySaver,
        if (customSavePath != null) 'customSavePath': customSavePath,
        'themeMode': themeMode.name,
        if (xmpCreator != null) 'xmpCreator': xmpCreator,
        if (xmpRights != null) 'xmpRights': xmpRights,
        'xmpInjectRating': xmpInjectRating,
        'xmpInjectGps': xmpInjectGps,
        'watermarkStyle': watermarkStyle.name,
        if (watermarkText != null) 'watermarkText': watermarkText,
        'feedUpscaler': feedUpscaler.name,
        'temporalDenoise': temporalDenoise,
        'autoRotateFeed': autoRotateFeed,
        'deSqueeze': deSqueeze,
        'monitorGrid': monitorGrid,
        'monitorZebra': monitorZebra,
        'monitorHistogram': monitorHistogram,
        'monitorLevel': monitorLevel,
        'monitorFalseColor': monitorFalseColor,
        'monitorPeaking': monitorPeaking,
        'monitorFocusDial': monitorFocusDial,
        'liveViewOn': liveViewOn,
        if (liveViewImageSize != null)
          'liveViewImageSize': liveViewImageSize,
        if (liveViewImageCompression != null)
          'liveViewImageCompression': liveViewImageCompression,
        'sdramCapture': sdramCapture,
      };

  static AppSettings fromJson(Map<String, Object?> json) => AppSettings(
        autoTransfer: json['autoTransfer'] == true,
        autoTransferFormat:
            _enumByName(PhotoDownloadFormat.values, json['autoTransferFormat'])
                ?? PhotoDownloadFormat.both,
        quality:
            _enumByName(TransferQuality.values, json['quality']) ??
                TransferQuality.original,
        batterySaver: json['batterySaver'] == true,
        customSavePath: json['customSavePath'] as String?,
        themeMode:
            _enumByName(AppThemeMode.values, json['themeMode']) ??
                AppThemeMode.system,
        xmpCreator: json['xmpCreator'] as String?,
        xmpRights: json['xmpRights'] as String?,
        xmpInjectRating: json['xmpInjectRating'] == true,
        xmpInjectGps: json['xmpInjectGps'] == true,
        watermarkStyle: _enumByName(WatermarkStyle.values, json['watermarkStyle'])
            ?? WatermarkStyle.off,
        watermarkText: json['watermarkText'] as String?,
        feedUpscaler:
            _enumByName(FeedUpscaler.values, json['feedUpscaler']) ??
                FeedUpscaler.off,
        temporalDenoise: json['temporalDenoise'] == true,
        // 兼容旧档缺省 + 越界钳回 [1, 2](NaN/负数按关)。
        autoRotateFeed: json['autoRotateFeed'] == null ||
            json['autoRotateFeed'] == true,
        deSqueeze: _clampDeSqueeze(json['deSqueeze']),
        monitorGrid: json['monitorGrid'] == true,
        monitorZebra: json['monitorZebra'] == true,
        monitorHistogram: json['monitorHistogram'] == true,
        monitorLevel: json['monitorLevel'] == true,
        monitorFalseColor: json['monitorFalseColor'] == true,
        monitorPeaking: json['monitorPeaking'] == true,
        monitorFocusDial: json['monitorFocusDial'] == true,
        // 旧档缺省 = 开(保持「取景默认打开」原定案)。
        liveViewOn: json['liveViewOn'] == null || json['liveViewOn'] == true,
        liveViewImageSize: _pickLiveViewValue(json['liveViewImageSize'],
            const [1, 2, 3]),
        liveViewImageCompression: _pickLiveViewValue(
            json['liveViewImageCompression'], const [0, 1, 2, 3, 4, 5]),
        sdramCapture: json['sdramCapture'] == true,
      );

  /// 取景画质档反序列化:表外值(旧版本/手改文件)回落「跟随相机」。
  static int? _pickLiveViewValue(Object? raw, List<int> allowed) {
    if (raw is! int || !allowed.contains(raw)) return null;
    return raw;
  }

  static double _clampDeSqueeze(Object? raw) {
    if (raw is! num || raw.isNaN || raw.isNegative) return 1.0;
    return raw.clamp(1.0, 2.0).toDouble();
  }

  static T? _enumByName<T extends Enum>(List<T> values, Object? raw) {
    if (raw is! String) return null;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return null; // 未知值(旧版本/手改文件):回落默认
  }
}

abstract interface class SettingsStore {
  Stream<AppSettings> get settings;
  Future<AppSettings> current();
  Future<void> update(AppSettings settings);
}

/// JSON 文件实现:`<dataDir>/settings.json`,内存缓存 + 全量写回。
/// 损坏文件按默认设置重建(设置可重选,无损恢复)。
final class FileSettingsStore implements SettingsStore {
  FileSettingsStore({required Future<String> Function() dataDir})
      : _dataDir = dataDir;

  final Future<String> Function() _dataDir;
  final _ctrl = StreamController<AppSettings>.broadcast();
  AppSettings? _cache;
  Future<AppSettings>? _loading;

  @override
  Stream<AppSettings> get settings => _ctrl.stream;

  @override
  Future<AppSettings> current() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load();
  }

  Future<AppSettings> _load() async {
    AppSettings value = const AppSettings();
    final file = File('${await _dataDir()}/settings.json');
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, Object?>) {
          value = AppSettings.fromJson(json);
        }
      } on FormatException {
        // 损坏文件:按默认重建
      }
    }
    _cache = value;
    return value;
  }

  @override
  Future<void> update(AppSettings settings) async {
    _cache = settings;
    final file = File('${await _dataDir()}/settings.json');
    await file.create(recursive: true);
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(settings.toJson()));
    _ctrl.add(settings);
  }
}

final class InMemorySettingsStore implements SettingsStore {
  final _controller = StreamController<AppSettings>.broadcast();
  AppSettings _value = const AppSettings();

  @override
  Stream<AppSettings> get settings => _controller.stream;

  @override
  Future<AppSettings> current() async => _value;

  @override
  Future<void> update(AppSettings settings) async {
    _value = settings;
    _controller.add(settings);
  }
}
