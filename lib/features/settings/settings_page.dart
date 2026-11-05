/// 设置页:四组卡片(拍摄与监看 / 传输与存储 / 应用与外观 / 设备与诊断)。
///
/// 第 4 轮视觉:分组标题 + 16 圆角卡片、行前置图标、999 胶囊分段、琥珀
/// 开关;控制器与回调口径不变(所有存量设置项都保留,仅重排)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../core/log/app_log.dart';
import '../../core/media/watermark.dart';
import '../../data/settings_store.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../../platform/services.dart';
import '../common/widgets/states.dart' show InlineHint;
import 'log_section.dart' show buildLogSection;
import 'settings_widgets.dart';
import 'snapshot_controller.dart' show buildSnapshotSection;

/// 取景页/取景区消费设置(deSqueeze)时把本控制器当
/// [ValueListenable] 直挂:监听即 ChangeNotifier,值即 [settings]。
class SettingsController extends ChangeNotifier
    implements ValueListenable<AppSettings> {
  SettingsController({required this.store}) {
    _sub = store.settings.listen((s) {
      if (s == settings) return; // 自己写回的同值:不再二次通知
      settings = s;
      notifyListeners();
    });
    unawaited(_load());
  }

  final SettingsStore store;
  AppSettings settings = const AppSettings();

  @override
  AppSettings get value => settings;

  StreamSubscription<AppSettings>? _sub;

  /// 待落盘快照(单槽latest-wins):滑杆连续拖动只保留最后一版,
  /// 写盘串行,旧值晚到不会覆盖新值。
  AppSettings? _pendingPersist;
  bool _persistWriting = false;
  bool _persistFailed = false;
  bool _disposed = false;

  /// 最近一次写盘是否失败(设置页顶部出可重试提示)。
  bool get persistFailed => _persistFailed;

  Future<void> _load() async {
    try {
      settings = await store.current();
    } on Object {
      // 存储不可用(通道未就绪等):保持默认,开关仍可临时改(不持久)
    }
    notifyListeners();
  }

  Future<void> setThemeMode(AppThemeMode value) =>
      _update(settings.copyWith(themeMode: value));

  /// 界面语言(i18n 第一期):选中即存,app 根沿重建 L10nScope。
  Future<void> setLanguage(AppLanguage value) =>
      _update(settings.copyWith(language: value));

  Future<void> setAutoTransfer(bool value) =>
      _update(settings.copyWith(autoTransfer: value));

  Future<void> setAutoTransferFormat(PhotoDownloadFormat value) =>
      _update(settings.copyWith(autoTransferFormat: value));

  Future<void> setXmpCreator(String value) =>
      _update(settings.copyWith(xmpCreator: value));

  Future<void> setXmpRights(String value) =>
      _update(settings.copyWith(xmpRights: value));

  Future<void> setXmpInjectRating(bool value) =>
      _update(settings.copyWith(xmpInjectRating: value));

  Future<void> setXmpInjectGps(bool value) =>
      _update(settings.copyWith(xmpInjectGps: value));

  Future<void> setWatermarkStyle(WatermarkStyle value) =>
      _update(settings.copyWith(watermarkStyle: value));

  Future<void> setWatermarkText(String value) =>
      _update(settings.copyWith(watermarkText: value));

  Future<void> setFeedUpscaler(FeedUpscaler value) =>
      _update(settings.copyWith(feedUpscaler: value));

  Future<void> setTemporalDenoise(bool value) =>
      _update(settings.copyWith(temporalDenoise: value));

  Future<void> setDeSqueeze(double value, {bool persist = true}) =>
      _update(settings.copyWith(deSqueeze: value.clamp(1.0, 2.0)),
          persist: persist);

  /// 整对象落库(十二轮:拍摄页监看开关组/取景开关经 copyWith 拼好
  /// 后从这里走 —— 与散装 setter 同一条 _update 路,存储失败仅吞)。
  Future<void> apply(AppSettings next) => _update(next);

  /// BLE GPS 注入总开关(连接页/拍摄浮层芯片双入口,同一条路)。
  Future<void> setBleGpsInject(bool value) =>
      _update(settings.copyWith(bleGpsInject: value));

  /// 连接页上次选中的连接方式(存 ConnectionMethod 枚举名;恢复在
  /// ConnectionController,本控制器只管落库)。
  Future<void> setConnectionMethod(String value) =>
      _update(settings.copyWith(connectionMethod: value));

  Future<void> _update(AppSettings next, {bool persist = true}) async {
    if (next == settings) return; // 同值:不通知、不落库
    settings = next;
    notifyListeners();
    if (!persist) return;
    _pendingPersist = next;
    await _drainPersist();
  }

  /// 写盘串行 + 单槽合并:同一时刻只有一个 store.update 在途,期间
  /// 新的设置只覆盖待写快照;失败置 [persistFailed],由设置页顶部
  /// 提示重试(不再静默吞掉)。
  Future<void> _drainPersist() async {
    if (_persistWriting) return;
    _persistWriting = true;
    try {
      while (_pendingPersist != null) {
        final next = _pendingPersist!;
        _pendingPersist = null;
        try {
          await store.update(next);
          if (_persistFailed) {
            _persistFailed = false;
            if (!_disposed) notifyListeners();
          }
        } on Object catch (e) {
          _persistFailed = true;
          AppLog.e(AppLog.system, '设置持久化失败:$e');
          if (!_disposed) notifyListeners();
        }
      }
    } finally {
      _persistWriting = false;
    }
  }

  /// 用户点「重试」:把当前设置重新排队落盘。
  Future<void> retryPersist() async {
    if (!_persistFailed) return;
    _pendingPersist = settings;
    await _drainPersist();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    super.dispose();
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _creatorCtrl;
  late final TextEditingController _rightsCtrl;
  late final TextEditingController _watermarkCtrl;
  late final FocusNode _creatorFocus;
  late final FocusNode _rightsFocus;
  late final FocusNode _watermarkFocus;

  @override
  void initState() {
    super.initState();
    final controller = AppServices.instance.settingsController;
    final s = controller.settings;
    _creatorCtrl = TextEditingController(text: s.xmpCreator ?? '');
    _rightsCtrl = TextEditingController(text: s.xmpRights ?? '');
    _watermarkCtrl = TextEditingController(text: s.watermarkText ?? '');
    // 焦点离开即落库:手机上没有「回车提交」的心智,输完点走就该生效
    // —— 只挂 onSubmitted 会静默丢输入。
    _creatorFocus = _commitOnBlur(_creatorCtrl, controller.setXmpCreator);
    _rightsFocus = _commitOnBlur(_rightsCtrl, controller.setXmpRights);
    _watermarkFocus =
        _commitOnBlur(_watermarkCtrl, controller.setWatermarkText);
  }

  FocusNode _commitOnBlur(
      TextEditingController ctrl, ValueSetter<String> save) {
    final node = FocusNode();
    node.addListener(() {
      if (!node.hasFocus) {
        save(ctrl.text);
      }
    });
    return node;
  }

  @override
  void dispose() {
    _creatorCtrl.dispose();
    _rightsCtrl.dispose();
    _watermarkCtrl.dispose();
    _creatorFocus.dispose();
    _rightsFocus.dispose();
    _watermarkFocus.dispose();
    super.dispose();
  }

  /// GPS 注入开关(唯一开关入口,2026-10-18 自连接页收编;拍摄浮层
  /// 芯片同一条设置路):打开沿复查授权态定成败 —— 「始终」或「仅使
  /// 用中」皆放行(2026-10-21 试验改:10-13 账本「whenInUse 退后台即
  /// 停」与 SnapBridge 仅使用中可用的实证相抵,待真机 A/B 复核;仅使
  /// 用中的后台续命 = allowsBackgroundLocationUpdates 后台会话蓝胶囊
  /// 路径)。**未授权一律请求**(notDetermined/denied 都走):Android
  /// 的 authStatus 未授权恒回 'denied'、无持久未定态,旧逻辑只认
  /// notDetermined → 撤销权限后再开开关只出内置提示、永不弹系统框
  /// (2026-11-05 修);Android/ohos 的 native request 在系统授权结果
  /// 落定时才返回,await 后复查即可;iOS 的 request 先返回、结果由
  /// delegate 异步落定,仍需轮询(用户手速不一,10s 上限;固定 2s 会
  /// 跟手速赛跑,2026-10-21 真机实证:用户 6s 才点允许,2s 查询扑空,
  /// 开关误翻回把注入层整个拆了)。拒授/受限/通道缺失即切换失败翻回,
  /// 不落库;关闭直落。注入驱动刷新由 AppServices 的 settingsController
  /// 监听收口,此处不碰驱动。
  Future<void> _setBleGpsInject(
      BuildContext context, SettingsController controller, bool on) async {
    if (!on) {
      await controller.setBleGpsInject(false);
      return;
    }
    var granted = false;
    try {
      var status = await PlatformServices.locationStream.authorizationStatus();
      if (status != 'always' && status != 'whenInUse') {
        await PlatformServices.locationStream.requestAlwaysAuthorization();
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          // iOS:系统弹窗落定时长不定(用户手速),轮询等授权离开未定态,
          // 上限 10s。
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            status = await PlatformServices.locationStream.authorizationStatus();
            if (status != 'notDetermined') break;
          }
        } else {
          // Android/ohos:native request 已等到系统授权结果返回,复查一次。
          status = await PlatformServices.locationStream.authorizationStatus();
        }
      }
      granted = status == 'always' || status == 'whenInUse';
    } on Exception {
      granted = false;
    }
    if (!granted) {
      if (context.mounted) {
        setState(() {}); // 开关翻回(值未落库,重建即对齐)
        ScaffoldMessenger.of(context)
          ..removeCurrentSnackBar()
          ..showSnackBar(
              SnackBar(content: Text(context.t('conn.gpsAuthFailed'))));
      }
      return;
    }
    await controller.setBleGpsInject(true);
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppServices.instance.settingsController;
    return Scaffold(
      // 第 4 轮设计稿:设置标题左对齐(三十轮「唯一显式居中顶栏」随
      // 设计稿收编)。搜索未做真实过滤,不放图标 —— 无假按钮。
      appBar: AppBar(
        centerTitle: true,
        toolbarHeight: AppSizes.appBarPortrait,
        title: Text(context.t('common.settings'),
            // 2026-10-30:与相机页「相机」同字号(titleLarge),三 tab 统一。
            style: Theme.of(context).textTheme.titleLarge),
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => GestureDetector(
          // 点空白散焦收键盘:文本框自身的点按由它的手势竞技场赢下,不冲突
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (controller.persistFailed)
                  InlineHint(
                    message: const (key: 'settings.persistFailed', args: null),
                    actionLabel: context.t('common.retry'),
                    onAction: () => unawaited(controller.retryPersist()),
                  ),
                _captureSection(context, controller),
                _transferSection(context, controller),
                _appearanceSection(context, controller),
                _deviceSection(context, controller),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _captureSection(BuildContext context, SettingsController controller) {
    final s = controller.settings;
    return SettingsSection(
      titleKey: 'settings.sectionCapture',
      children: [
        SettingsControlRow(
          leading: Icons.auto_awesome,
          title: context.t('settings.upscaling'),
          // 设计稿副题 = 三档并陈(关 · 快速 · 高质量)。
          subtitle: [
            context.t('common.offShort'),
            context.t('common.fast'),
            context.t('common.highQuality'),
          ].join(' · '),
          child: SettingsSegment<FeedUpscaler>(
            value: s.feedUpscaler,
            options: [
              (value: FeedUpscaler.off, label: context.t('common.offShort')),
              (value: FeedUpscaler.fast, label: context.t('common.fast')),
              (
                value: FeedUpscaler.quality,
                label: context.t('common.highQuality')
              ),
            ],
            onChanged: controller.setFeedUpscaler,
          ),
        ),
        SettingsSwitchRow(
          leading: Icons.blur_on,
          title: context.t('settings.temporalDenoise'),
          subtitle: context.t('settings.temporalDenoiseSubtitle'),
          value: s.temporalDenoise,
          onChanged: controller.setTemporalDenoise,
        ),
        SettingsControlRow(
          leading: Icons.aspect_ratio,
          title: context.t('settings.desqueeze'),
          subtitle: context.t('settings.desqueezeSubtitle',
              {'v': s.deSqueeze.toStringAsFixed(2)}),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: AppSpacing.xs + 2,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final preset in kDeSqueezePresets)
                    SettingsPillChip(
                      label: preset == 1.0
                          ? context.t('common.offShort')
                          : '$preset×',
                      selected: s.deSqueeze == preset,
                      onSelected: () => controller.setDeSqueeze(preset),
                    ),
                ],
              ),
              Slider(
                min: 1.0,
                max: 2.0,
                divisions: 100,
                label: '${s.deSqueeze.toStringAsFixed(2)}×',
                value: s.deSqueeze,
                activeColor: AppColors.accentYellow,
                inactiveColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                onChanged: (v) =>
                    controller.setDeSqueeze(v, persist: false),
                onChangeEnd: controller.setDeSqueeze,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _transferSection(BuildContext context, SettingsController controller) {
    final s = controller.settings;
    return SettingsSection(
      titleKey: 'settings.sectionTransfer',
      children: [
        SettingsSwitchRow(
          leading: Icons.bolt,
          title: context.t('settings.autoTransfer'),
          subtitle: context.t('settings.autoTransferSubtitle'),
          value: s.autoTransfer,
          onChanged: controller.setAutoTransfer,
        ),
        SettingsControlRow(
          leading: Icons.photo_size_select_large,
          title: context.t('settings.quickFormat'),
          subtitle: context.t('settings.quickFormatSubtitle'),
          child: SettingsSegment<PhotoDownloadFormat>(
            value: s.autoTransferFormat,
            // 四段窄屏:选中不加 ✓,段文案钉单行(鸿蒙在 "+" 处会断行)。
            showSelectedIcon: false,
            options: [
              for (final f in PhotoDownloadFormat.values)
                (value: f, label: context.t(f.short)),
            ],
            onChanged: controller.setAutoTransferFormat,
          ),
        ),
        SettingsRow(
          leading: Icons.high_quality_outlined,
          title: context.t('settings.transferQuality'),
          subtitle: context.t('settings.transferQualitySubtitle'),
          enabled: false,
        ),
        SettingsRow(
          leading: Icons.data_object,
          title: context.t('settings.xmpInjection'),
          subtitle: context.t('settings.xmpSubtitle'),
        ),
        SettingsTextField(
          controller: _creatorCtrl,
          focusNode: _creatorFocus,
          label: context.t('settings.xmpAuthor'),
          onSubmitted: controller.setXmpCreator,
        ),
        SettingsTextField(
          controller: _rightsCtrl,
          focusNode: _rightsFocus,
          label: context.t('settings.xmpCopyright'),
          onSubmitted: controller.setXmpRights,
        ),
        SettingsSwitchRow(
          leading: Icons.star_outline,
          title: context.t('settings.writeRating'),
          subtitle: context.t('settings.writeRatingSubtitle'),
          value: s.xmpInjectRating,
          onChanged: controller.setXmpInjectRating,
        ),
        SettingsSwitchRow(
          leading: Icons.location_on_outlined,
          title: context.t('settings.writeGps'),
          subtitle: context.t('settings.writeGpsSubtitle'),
          value: s.xmpInjectGps,
          onChanged: controller.setXmpInjectGps,
        ),
        SettingsControlRow(
          leading: Icons.branding_watermark_outlined,
          title: context.t('settings.watermark'),
          subtitle: context.t('settings.watermarkSubtitle'),
          child: SettingsSegment<WatermarkStyle>(
            value: s.watermarkStyle,
            options: [
              (value: WatermarkStyle.off, label: context.t('common.off')),
              (
                value: WatermarkStyle.corner,
                label: context.t('settings.badge')
              ),
              (
                value: WatermarkStyle.card,
                label: context.t('settings.photoCard')
              ),
            ],
            onChanged: controller.setWatermarkStyle,
          ),
        ),
        if (s.watermarkStyle != WatermarkStyle.off)
          SettingsTextField(
            controller: _watermarkCtrl,
            focusNode: _watermarkFocus,
            label: context.t('settings.watermarkText'),
            onSubmitted: controller.setWatermarkText,
          ),
      ],
    );
  }

  Widget _appearanceSection(
      BuildContext context, SettingsController controller) {
    final s = controller.settings;
    return SettingsSection(
      titleKey: 'settings.sectionAppearance',
      children: [
        SettingsControlRow(
          title: context.t('settings.theme'),
          subtitle: context.t('settings.darkModeSubtitle'),
          child: SettingsSegment<AppThemeMode>(
            value: s.themeMode,
            options: [
              (
                value: AppThemeMode.system,
                label: context.t('common.followSystem')
              ),
              (value: AppThemeMode.light, label: context.t('theme.light')),
              (value: AppThemeMode.dark, label: context.t('theme.dark')),
            ],
            onChanged: controller.setThemeMode,
          ),
        ),
        SettingsControlRow(
          title: context.t('settings.language'),
          subtitle: context.t('settings.languageSubtitle'),
          child: SettingsSegment<AppLanguage>(
            value: s.language,
            options: [
              for (final l in AppLanguage.values)
                (value: l, label: context.t(l.label)),
            ],
            onChanged: controller.setLanguage,
          ),
        ),
        SettingsRow(
          leading: Icons.text_fields,
          title: context.t('settings.fontSize'),
          subtitle: context.t('settings.fontSizeSubtitle'),
          trailing: Text(
            '${MediaQuery.textScalerOf(context).scale(1).toStringAsFixed(2)}×',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _deviceSection(BuildContext context, SettingsController controller) {
    final s = controller.settings;
    return SettingsSection(
      titleKey: 'settings.sectionDevice',
      // 快照区自带首条 Divider(与 GPS 行分隔),不能再自动插线。
      insertDividers: false,
      children: [
        // BLE GPS 注入总开关(2026-10-18 自连接页收编):打开沿
        // 申请后台定位授权,失败即翻回不落库(见 _setBleGpsInject)。
        SettingsSwitchRow(
          leading: Icons.bluetooth,
          title: context.t('conn.gpsInjection'),
          subtitle: context.t('conn.gpsInjectionHint'),
          value: s.bleGpsInject,
          onChanged: (on) =>
              unawaited(_setBleGpsInject(context, controller, on)),
        ),
        buildSnapshotSection(context),
        const Divider(height: 1),
        buildLogSection(context),
      ],
    );
  }
}
