/// 设置仓库:[AppSettings] 模型 + 文件/内存实现。
///
/// 持久化走 JSON 文件(`<dataDir>/settings.json`,全量写回 + 内存缓存),
/// 与配对档案同款;T4 的水印/LUT 等字段后续在 [AppSettings] 上扩。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/browser/photo_group.dart';

enum TransferQuality { original, compressed }

/// 水印模板:off 关闭;corner 角标;card 摄影卡片。
enum WatermarkStyle { off, corner, card }

/// 深浅模式(system = 跟随系统;light/dark = 锁定)。独立于 Material
/// 的 ThemeMode 枚举 —— data 层不依赖 Flutter,app 根再做映射。
enum AppThemeMode { system, light, dark }

/// 界面语言(2026-10-14 i18n 第一期):默认中文(「可跟随系统,默认为
/// 中文」),可锁 English。独立于 Material 的 Locale —— t() 的语言来源
/// 是 app 根装配的 L10nScope(见 l10n/l10n.dart),框架组件内置文案另
/// 走 flutter_localizations,app 根再做两条映射。
enum AppLanguage {
  system, zh, en;

  /// 设置页选择器文案 = t() 键(l10n 抽象键制)。「中文」是语言专名,
  /// 英文环境也不译(zhCatalog/enCatalog 同款映射)。
  String get label => switch (this) {
        system => 'common.followSystem',
        zh => 'lang.zh',
        en => 'lang.en',
      };
}

/// 取景画面上采样档(OpenZCine FeedUpscaler 口径,AI 档未引 ——
/// 无 CoreML 接线,不虚设):off = 现状(低质采样);fast = Flutter
/// 内建 cubic(FilterQuality.high,零额外开销);quality = 片元着色器
/// (Catmull-Rom 上采样 + 锐化,可叠时域降噪)。
enum FeedUpscaler { off, fast, quality }

/// 构图框遮幅画幅(OpenZCine FramingGuides 口径):off 关闭;其余 =
/// 目标画幅比,门框外压暗。变宽还原拉伸发生在显示层,遮幅门在图像系
/// 按 ratio/deSqueeze 预缩 —— 屏上观感即目标画幅(见
/// live_view_overlays.dart 的 FramingOverlay)。
enum FramingAspect {
  off, a239, a235, a185;

  /// 目标画幅比(null = off,不画遮幅)。
  double? get ratio => switch (this) {
        off => null,
        a239 => 2.39,
        a235 => 2.35,
        a185 => 1.85,
      };

  /// 芯片文案(「2.39」等;off 空)。
  String get label => switch (this) {
        off => '',
        a239 => '2.39',
        a235 => '2.35',
        a185 => '1.85',
      };

  /// 芯片点按循环下一档(off → 2.39 → 2.35 → 1.85 → off)。
  FramingAspect get next =>
      FramingAspect.values[(index + 1) % FramingAspect.values.length];
}

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
    this.language = AppLanguage.zh,
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
    this.monitorPeakingLevel = 1,
    this.monitorPeakingColor = 0,
    this.monitorPeakingEngine = 0,
    this.monitorFocusDial = false,
    this.framingAspect = FramingAspect.off,
    this.framingSafeArea = false,
    this.framingCenterMark = false,
    this.monitorWaveform = false,
    this.monitorScope = 0,
    this.monitorScopeNLog = false,
    this.monitorLutIndex = -1,
    this.liveViewOn = true,
    this.liveViewImageSize = 3,
    this.liveViewImageCompression = 5,
    this.sdramCapture = false,
    this.bleGpsInject = false,
    this.volumeKeyShutter = false,
    this.connectionMethod = 'usb',
  });

  final bool autoTransfer;

  /// 速传(ObjectAdded 自动下载)的格式过滤:双格式照片组按此选文件。
  final PhotoDownloadFormat autoTransferFormat;

  final TransferQuality quality; // P3:传输质量(压缩路径未实现,暂不消费)
  final bool batterySaver; // P3:省电模式(未消费)
  final String? customSavePath; // P3:自定义存储路径(未消费)

  /// 深浅模式:默认跟随系统,设置页可锁定。
  final AppThemeMode themeMode;

  /// 界面语言:默认中文(可跟随系统);消费在 app 根(L10nScope +
  /// MaterialApp locale 映射,见 app.dart)。
  final AppLanguage language;

  /// XMP 元数据注入:作者(dc:creator),空 = 不写该字段。
  final String? xmpCreator;

  /// 版权声明(dc:rights),空 = 不写该字段。
  final String? xmpRights;

  /// 下载 JPG 时把本地评分写入 xmp:Rating。
  final bool xmpInjectRating;

  /// 下载 JPG 时把当前位置写入 EXIF GPS(经 zpill/location 通道)。
  final bool xmpInjectGps;

  /// 下载 JPG 合成水印:模板选择,off = 不合成。
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

  /// 峰值灵敏度档(0=低/1=中/2=高):中 = 旧写死梯度阈值 40(行为
  /// 不变)。**调优档非协议常量** —— 档位 → 阈值映射在监看桥接层
  /// (features/remote/monitor_toggles.dart 的 monitorPeakingThresholdOf)。
  final int monitorPeakingLevel;

  /// 峰值高亮色档(0=金/1=白/2=红;金 = 旧行为)。取色在显示层
  /// (features/remote/live_view_overlays.dart 的 peakingColorOf)。
  final int monitorPeakingColor;

  /// 峰值算法档(0=双尺度比值,默认;1=经典单尺度梯度,2026-10-14
  /// 前唯一路径,保留手感回退)。引擎映射在监看桥接层
  /// (features/remote/monitor_toggles.dart 的 peakingEngineOf),
  /// 算法在 core/remote/peaking_engines.dart。
  final int monitorPeakingEngine;

  /// 构图框(OpenZCine 差集):遮幅画幅 + 安全框 + 中心标;门框数学
  /// 与绘制见 live_view_overlays.dart 的 FramingOverlay。
  final FramingAspect framingAspect;
  final bool framingSafeArea;
  final bool framingCenterMark;

  /// **旧档字段**:2026-10-15 前波形示波器的布尔开关,示波器族四选一
  /// 起改为 [monitorScope] 后保留作迁移源(读侧升级、写侧随 scope 保
  /// 连贯,见 features/remote/monitor_toggles.dart 的
  /// monitorTogglesFromSettings)。
  final bool monitorWaveform;

  /// 示波器档(0=关/1=波形/2=RGB Parade/3=矢量/4=红绿灯;缺省关)。
  /// 表外值回落关;面板芯片循环切换,四示波器共享帧分析。
  final int monitorScope;

  /// 示波器 Y 轴 N-Log 刻度(波形/Parade 下消费;默认关)。手动档:
  /// 相机 N-Log 态(0xD0BB)自动跟随留账,见 core/remote/scopes.dart。
  final bool monitorScopeNLog;

  /// 监看 LUT 索引(-1 = 关;0..n = 内置风格表序)。越界值按关消费
  /// (见 features/remote/monitor_toggles.dart 的 monitorLutOf),
  /// data 层不依赖 features,不做范围钳制。
  final int monitorLutIndex;

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

  /// BLE GPS 注入(0x2007):开 = 与已配对相机保持 BLE 会话并持续注入
  /// 定位(拍进卡的 NEF/JPG 原生带 EXIF 坐标);未配对时开关无效,
  /// 配对入口在设置页。
  final bool bleGpsInject;

  /// 音量键快门:开 = 拍摄页存续期原生拦音量键转快门(上/下
  /// 同效,命中走 RemoteController.capture 同一守卫);关/异端 = 音量键
  /// 归系统。Android 拦键事件、iOS 观察系统音量沿(启用期音量会被
  /// 回吸到锚点,停用还原),ohos 未做原生拦截。
  final bool volumeKeyShutter;

  /// 连接页上次选中的连接方式(枚举名:usb/ap/sta/ble)。data 层不依
  /// 赖 features 的 ConnectionMethod 枚举,只存名字;表外值由消费侧
  /// (ConnectionController)回落有线。
  final String connectionMethod;

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
    AppLanguage? language,
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
    int? monitorPeakingLevel,
    int? monitorPeakingColor,
    int? monitorPeakingEngine,
    bool? monitorFocusDial,
    FramingAspect? framingAspect,
    bool? framingSafeArea,
    bool? framingCenterMark,
    bool? monitorWaveform,
    int? monitorScope,
    bool? monitorScopeNLog,
    int? monitorLutIndex,
    bool? liveViewOn,
    Object? liveViewImageSize = _unset,
    Object? liveViewImageCompression = _unset,
    bool? sdramCapture,
    bool? bleGpsInject,
    bool? volumeKeyShutter,
    String? connectionMethod,
  }) =>
      AppSettings(
        autoTransfer: autoTransfer ?? this.autoTransfer,
        autoTransferFormat: autoTransferFormat ?? this.autoTransferFormat,
        quality: quality ?? this.quality,
        batterySaver: batterySaver ?? this.batterySaver,
        customSavePath: customSavePath ?? this.customSavePath,
        themeMode: themeMode ?? this.themeMode,
        language: language ?? this.language,
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
        monitorPeakingLevel: monitorPeakingLevel ?? this.monitorPeakingLevel,
        monitorPeakingColor: monitorPeakingColor ?? this.monitorPeakingColor,
        monitorPeakingEngine:
            monitorPeakingEngine ?? this.monitorPeakingEngine,
        monitorFocusDial: monitorFocusDial ?? this.monitorFocusDial,
        framingAspect: framingAspect ?? this.framingAspect,
        framingSafeArea: framingSafeArea ?? this.framingSafeArea,
        framingCenterMark: framingCenterMark ?? this.framingCenterMark,
        monitorWaveform: monitorWaveform ?? this.monitorWaveform,
        monitorScope: monitorScope ?? this.monitorScope,
        monitorScopeNLog: monitorScopeNLog ?? this.monitorScopeNLog,
        monitorLutIndex: monitorLutIndex ?? this.monitorLutIndex,
        liveViewOn: liveViewOn ?? this.liveViewOn,
        liveViewImageSize: liveViewImageSize == _unset
            ? this.liveViewImageSize
            : liveViewImageSize as int?,
        liveViewImageCompression: liveViewImageCompression == _unset
            ? this.liveViewImageCompression
            : liveViewImageCompression as int?,
        sdramCapture: sdramCapture ?? this.sdramCapture,
        bleGpsInject: bleGpsInject ?? this.bleGpsInject,
        volumeKeyShutter: volumeKeyShutter ?? this.volumeKeyShutter,
        connectionMethod: connectionMethod ?? this.connectionMethod,
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
      other.language == language &&
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
      other.monitorPeakingLevel == monitorPeakingLevel &&
      other.monitorPeakingColor == monitorPeakingColor &&
      other.monitorPeakingEngine == monitorPeakingEngine &&
      other.monitorFocusDial == monitorFocusDial &&
      other.framingAspect == framingAspect &&
      other.framingSafeArea == framingSafeArea &&
      other.framingCenterMark == framingCenterMark &&
      other.monitorWaveform == monitorWaveform &&
      other.monitorScope == monitorScope &&
      other.monitorScopeNLog == monitorScopeNLog &&
      other.monitorLutIndex == monitorLutIndex &&
      other.liveViewOn == liveViewOn &&
      other.liveViewImageSize == liveViewImageSize &&
      other.liveViewImageCompression == liveViewImageCompression &&
      other.sdramCapture == sdramCapture &&
      other.bleGpsInject == bleGpsInject &&
      other.volumeKeyShutter == volumeKeyShutter &&
      other.connectionMethod == connectionMethod;

  @override
  // Object.hash 位置参上限 20,字段 37 个 → hashAll(列表序即上面 == 序)。
  int get hashCode => Object.hashAll([
        autoTransfer, autoTransferFormat, quality, batterySaver, customSavePath,
        themeMode, language, xmpCreator, xmpRights, xmpInjectRating, xmpInjectGps,
        watermarkStyle, watermarkText, feedUpscaler, temporalDenoise,
        autoRotateFeed, deSqueeze,
        monitorGrid, monitorZebra, monitorHistogram, monitorLevel,
        monitorFalseColor, monitorPeaking, monitorPeakingLevel,
        monitorPeakingColor, monitorPeakingEngine, monitorFocusDial,
        framingAspect, framingSafeArea, framingCenterMark,
        monitorWaveform, monitorScope, monitorScopeNLog, monitorLutIndex,
        liveViewOn,
        liveViewImageSize, liveViewImageCompression, sdramCapture,
        bleGpsInject, volumeKeyShutter, connectionMethod,
      ]);

  Map<String, Object?> toJson() => {
        'autoTransfer': autoTransfer,
        'autoTransferFormat': autoTransferFormat.name,
        'quality': quality.name,
        'batterySaver': batterySaver,
        if (customSavePath != null) 'customSavePath': customSavePath,
        'themeMode': themeMode.name,
        'language': language.name,
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
        'monitorPeakingLevel': monitorPeakingLevel,
        'monitorPeakingColor': monitorPeakingColor,
        'monitorPeakingEngine': monitorPeakingEngine,
        'monitorFocusDial': monitorFocusDial,
        'framingAspect': framingAspect.name,
        'framingSafeArea': framingSafeArea,
        'framingCenterMark': framingCenterMark,
        'monitorWaveform': monitorWaveform,
        'monitorScope': monitorScope,
        'monitorScopeNLog': monitorScopeNLog,
        'monitorLutIndex': monitorLutIndex,
        'liveViewOn': liveViewOn,
        if (liveViewImageSize != null)
          'liveViewImageSize': liveViewImageSize,
        if (liveViewImageCompression != null)
          'liveViewImageCompression': liveViewImageCompression,
        'sdramCapture': sdramCapture,
        'bleGpsInject': bleGpsInject,
        'volumeKeyShutter': volumeKeyShutter,
        'connectionMethod': connectionMethod,
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
        // 旧档缺键/表外值回落中文(默认档,同 themeMode 口径)。
        language: _enumByName(AppLanguage.values, json['language']) ??
            AppLanguage.zh,
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
        // 旧档缺省/表外值回落默认档(中灵敏度/金色 = 旧行为)。
        monitorPeakingLevel:
            _pickEnumIndex(json['monitorPeakingLevel'], const [0, 1, 2], 1),
        monitorPeakingColor:
            _pickEnumIndex(json['monitorPeakingColor'], const [0, 1, 2], 0),
        // 旧版本文件无此键 → 默认双尺度;表外值回落同档。
        monitorPeakingEngine:
            _pickEnumIndex(json['monitorPeakingEngine'], const [0, 1], 0),
        monitorFocusDial: json['monitorFocusDial'] == true,
        framingAspect: _enumByName(FramingAspect.values, json['framingAspect']) ??
            FramingAspect.off,
        framingSafeArea: json['framingSafeArea'] == true,
        framingCenterMark: json['framingCenterMark'] == true,
        monitorWaveform: json['monitorWaveform'] == true,
        // 示波器档:旧档缺键(= 0 关)/表外值回落关。
        monitorScope:
            _pickEnumIndex(json['monitorScope'], const [0, 1, 2, 3, 4], 0),
        monitorScopeNLog: json['monitorScopeNLog'] == true,
        // 表外值(负数/手改)不做范围钳制,消费侧按关(LUT 表外 = null)。
        monitorLutIndex: json['monitorLutIndex'] is int
            ? json['monitorLutIndex'] as int
            : -1,
        // 旧档缺省 = 开(保持「取景默认打开」原定案)。
        liveViewOn: json['liveViewOn'] == null || json['liveViewOn'] == true,
        liveViewImageSize: _pickLiveViewValue(json['liveViewImageSize'],
            const [1, 2, 3]),
        liveViewImageCompression: _pickLiveViewValue(
            json['liveViewImageCompression'], const [0, 1, 2, 3, 4, 5]),
        sdramCapture: json['sdramCapture'] == true,
        // 旧档无键回落 false(「跟随相机」同款语义:无键不覆写)。
        bleGpsInject: json['bleGpsInject'] == true,
        volumeKeyShutter: json['volumeKeyShutter'] == true,
        // 表外值不在此钳(消费侧 ConnectionController 回落 usb)。
        connectionMethod:
            json['connectionMethod'] is String
                ? json['connectionMethod'] as String
                : 'usb',
      );

  /// 取景画质档反序列化:表外值(旧版本/手改文件)回落「跟随相机」。
  static int? _pickLiveViewValue(Object? raw, List<int> allowed) {
    if (raw is! int || !allowed.contains(raw)) return null;
    return raw;
  }

  /// 枚举档反序列化:非 int/表外值(旧版本/手改文件)回落默认档。
  static int _pickEnumIndex(Object? raw, List<int> allowed, int fallback) {
    if (raw is! int || !allowed.contains(raw)) return fallback;
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
