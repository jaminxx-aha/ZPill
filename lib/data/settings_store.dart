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
      other.deSqueeze == deSqueeze;

  @override
  int get hashCode => Object.hash(
      autoTransfer, autoTransferFormat, quality, batterySaver, customSavePath,
      themeMode, xmpCreator, xmpRights, xmpInjectRating, xmpInjectGps,
      watermarkStyle, watermarkText, feedUpscaler, temporalDenoise,
      autoRotateFeed, deSqueeze);

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
      );

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
