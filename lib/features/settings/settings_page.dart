/// 设置页:深浅模式/速传开关/格式/水印/LUT/日志。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../data/settings_store.dart';
import '../../l10n/l10n.dart';
import '../../platform/services.dart';
import 'snapshot_controller.dart' show buildSnapshotSection;
import 'log_section.dart' show buildLogSection;

/// 取景页/取景区消费设置(autoRotateFeed/deSqueeze)时把本控制器当
/// [ValueListenable] 直挂:监听即 ChangeNotifier,值即 [settings]。
class SettingsController extends ChangeNotifier
    implements ValueListenable<AppSettings> {
  SettingsController({required this.store}) {
    _sub = store.settings.listen((s) {
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

  Future<void> setAutoRotateFeed(bool value) =>
      _update(settings.copyWith(autoRotateFeed: value));

  Future<void> setDeSqueeze(double value) =>
      _update(settings.copyWith(deSqueeze: value.clamp(1.0, 2.0)));

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

  Future<void> _update(AppSettings next) async {
    settings = next;
    notifyListeners();
    try {
      await store.update(next);
    } on Object {
      // 持久化失败:本次会话内设置仍生效
    }
  }

  @override
  void dispose() {
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
  /// 路径);仅未定态才请求授权(requestAlways 未定时先弹「使用中」
  /// 一级窗;已「仅使用中」再调只会招来「升级始终」二次弹窗,污染试
  /// 验),拒授/受限/通道缺失即切换失败翻回,不落库;关闭直落。注入
  /// 驱动刷新由 AppServices 的 settingsController 监听收口,此处不碰
  /// 驱动。
  Future<void> _setBleGpsInject(
      BuildContext context, SettingsController controller, bool on) async {
    if (!on) {
      await controller.setBleGpsInject(false);
      return;
    }
    var granted = false;
    try {
      var status =
          await PlatformServices.locationStream.authorizationStatus();
      if (status == 'notDetermined') {
        await PlatformServices.locationStream.requestAlwaysAuthorization();
        // 系统弹窗落定时长不定(用户手速):轮询等授权离开未定态,上限
        // 10s。固定 2s 会跟手速赛跑 —— 2026-10-21 真机实证:用户 6s 才
        // 点允许,2s 查询扑空,开关误翻回把注入层整个拆了(BLE ready 后
        // 定位流再没起来,相机位置数据冻结)。
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          status =
              await PlatformServices.locationStream.authorizationStatus();
          if (status != 'notDetermined') break;
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
      appBar: AppBar(title: Text(context.t('common.settings'))),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => GestureDetector(
          // 点空白散焦收键盘:文本框自身的点按由它的手势竞技场赢下,不冲突
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              ListTile(
                title: Text(context.t('settings.darkMode')),
                subtitle: Text(context.t('settings.darkModeSubtitle')),
              ),
              // 主题三段走 t()(2026-10-16 真机 EN 抽查补漏;i18n-1 期
              // 刻意不包 —— settings_page_test 曾全树断言恰一处
              // 'Follow System',主题段同键再译即两处。现断言已收窄到
              // 各行子树,system 段撞义复用 common.followSystem)。
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<AppThemeMode>(
                  segments: [
                    ButtonSegment(
                        value: AppThemeMode.system,
                        label: Text(context.t('common.followSystem'))),
                    ButtonSegment(
                        value: AppThemeMode.light,
                        label: Text(context.t('theme.light'))),
                    ButtonSegment(
                        value: AppThemeMode.dark,
                        label: Text(context.t('theme.dark'))),
                  ],
                  selected: {controller.settings.themeMode},
                  onSelectionChanged: (s) =>
                      controller.setThemeMode(s.first),
                ),
              ),
              ListTile(
                title: Text(context.t('settings.language')),
                subtitle: Text(context.t('settings.languageSubtitle')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<AppLanguage>(
                  // 选项文案走 t():英文环境「跟随系统」→ Follow System
                  // (「中文」「English」为专名不译)。第一期基建里语言行
                  // 是唯一消费 enCatalog 的 UI,其余存量文案由后续抽取
                  // agent 逐步包 t()(未命中键回落中文,不误翻)。
                  segments: [
                    for (final l in AppLanguage.values)
                      ButtonSegment(value: l, label: Text(context.t(l.label))),
                  ],
                  selected: {controller.settings.language},
                  onSelectionChanged: (s) => controller.setLanguage(s.first),
                ),
              ),
              const Divider(),
              SwitchListTile(
                title: Text(context.t('settings.autoTransfer')),
                subtitle: Text(context.t('settings.autoTransferSubtitle')),
                value: controller.settings.autoTransfer,
                onChanged: controller.setAutoTransfer,
              ),
              ListTile(
                title: Text(context.t('settings.quickFormat')),
                subtitle: Text(context.t(
                    'settings.quickFormatSubtitle')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<PhotoDownloadFormat>(
                  segments: [
                    for (final f in PhotoDownloadFormat.values)
                      ButtonSegment(
                          value: f, label: Text(context.t(f.short))),
                  ],
                  selected: {
                    controller.settings.autoTransferFormat,
                  },
                  onSelectionChanged: (s) =>
                      controller.setAutoTransferFormat(s.first),
                ),
              ),
              const Divider(),
              // BLE GPS 注入总开关(2026-10-18 自连接页收编):打开沿
              // 申请后台定位授权,失败即翻回不落库(见 _setBleGpsInject)。
              SwitchListTile(
                title: Text(context.t('conn.gpsInjection')),
                subtitle: Text(context.t('conn.gpsInjectionHint')),
                value: controller.settings.bleGpsInject,
                onChanged: (on) =>
                    unawaited(_setBleGpsInject(context, controller, on)),
              ),
              const Divider(),
              ListTile(
                title: Text(context.t('settings.xmpInjection')),
                subtitle: Text(
                    context.t('settings.xmpSubtitle')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _creatorCtrl,
                  focusNode: _creatorFocus,
                  decoration: InputDecoration(
                    labelText: context.t('settings.xmpAuthor'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: controller.setXmpCreator,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _rightsCtrl,
                  focusNode: _rightsFocus,
                  decoration: InputDecoration(
                    labelText: context.t('settings.xmpCopyright'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: controller.setXmpRights,
                ),
              ),
              SwitchListTile(
                title: Text(context.t('settings.writeRating')),
                subtitle: Text(context.t('settings.writeRatingSubtitle')),
                value: controller.settings.xmpInjectRating,
                onChanged: controller.setXmpInjectRating,
              ),
              SwitchListTile(
                title: Text(context.t('settings.writeGps')),
                subtitle: Text(context.t('settings.writeGpsSubtitle')),
                value: controller.settings.xmpInjectGps,
                onChanged: controller.setXmpInjectGps,
              ),
              const Divider(),
              ListTile(
                title: Text(context.t('settings.watermark')),
                subtitle: Text(context.t('settings.watermarkSubtitle')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<WatermarkStyle>(
                  segments: [
                    ButtonSegment(
                        value: WatermarkStyle.off,
                        label: Text(context.t('common.off'))),
                    ButtonSegment(
                        value: WatermarkStyle.corner,
                        label: Text(context.t('settings.badge'))),
                    ButtonSegment(
                        value: WatermarkStyle.card,
                        label: Text(context.t('settings.photoCard'))),
                  ],
                  selected: {controller.settings.watermarkStyle},
                  onSelectionChanged: (s) =>
                      controller.setWatermarkStyle(s.first),
                ),
              ),
              if (controller.settings.watermarkStyle != WatermarkStyle.off)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _watermarkCtrl,
                    focusNode: _watermarkFocus,
                    decoration: InputDecoration(
                      labelText: context.t('settings.watermarkText'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: controller.setWatermarkText,
                  ),
                ),
              const Divider(),
              ListTile(
                title: Text(context.t('common.monitoring')),
                subtitle: Text(context.t('settings.monitoringSubtitle')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(context.t('settings.upscaling'),
                      style: const TextStyle(fontSize: 13)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<FeedUpscaler>(
                  segments: [
                    ButtonSegment(
                        value: FeedUpscaler.off, label: Text(context.t('common.offShort'))),
                    ButtonSegment(
                        value: FeedUpscaler.fast, label: Text(context.t('common.fast'))),
                    ButtonSegment(
                        value: FeedUpscaler.quality,
                        label: Text(context.t('common.highQuality'))),
                  ],
                  selected: {controller.settings.feedUpscaler},
                  onSelectionChanged: (s) =>
                      controller.setFeedUpscaler(s.first),
                ),
              ),
              SwitchListTile(
                title: Text(context.t('settings.temporalDenoise')),
                subtitle: Text(
                    context.t('settings.temporalDenoiseSubtitle')),
                value: controller.settings.temporalDenoise,
                onChanged: controller.setTemporalDenoise,
              ),
              SwitchListTile(
                title: Text(context.t('settings.autoRotate')),
                subtitle: Text(context.t('settings.autoRotateSubtitle')),
                value: controller.settings.autoRotateFeed,
                onChanged: controller.setAutoRotateFeed,
              ),
              ListTile(
                title: Text(context.t('settings.desqueeze')),
                subtitle: Text(context.t('settings.desqueezeSubtitle',
                    {'v': controller.settings.deSqueeze.toStringAsFixed(2)})),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final preset in kDeSqueezePresets)
                      ChoiceChip(
                        label: preset == 1.0
                            ? Text(context.t('common.offShort'))
                            : Text('$preset×'),
                        selected:
                            controller.settings.deSqueeze == preset,
                        onSelected: (_) =>
                            controller.setDeSqueeze(preset),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Slider(
                  min: 1.0,
                  max: 2.0,
                  divisions: 100,
                  label:
                      '${controller.settings.deSqueeze.toStringAsFixed(2)}×',
                  value: controller.settings.deSqueeze,
                  onChanged: controller.setDeSqueeze,
                ),
              ),
              const Divider(),
              ListTile(
                title: Text(context.t('settings.transferQuality')),
                subtitle: Text(context.t('settings.transferQualitySubtitle')),
                enabled: false,
              ),
              buildSnapshotSection(context),
              buildLogSection(context),
            ],
          ),
        ),
      ),
    );
  }
}
