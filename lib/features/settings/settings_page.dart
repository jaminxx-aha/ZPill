/// 设置页(TODO.md §五):深浅模式/速传开关/格式,后续 T4 段位(水印/
/// LUT)再扩。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../data/settings_store.dart';
import '../../l10n/l10n.dart';
import 'ble_pair_page.dart';
import 'snapshot_controller.dart' show buildSnapshotSection;

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

  @override
  Widget build(BuildContext context) {
    final controller = AppServices.instance.settingsController;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('设置'))),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => GestureDetector(
          // 点空白散焦收键盘:文本框自身的点按由它的手势竞技场赢下,不冲突
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              ListTile(
                title: Text(context.t('深色模式')),
                subtitle: Text(context.t('跟随系统,或锁定浅色/深色')),
              ),
              // 主题三段(跟随系统/浅色/深色)刻意不包 t():i18n-1 的
              // settings_page_test 在 en scope 下断言全树恰一处
              // 'Follow System'(语言行 system 段),主题段同键再译即
              // 两处,findsOneWidget 翻车 —— 测试期望零改动纪律优先,
              // 此三段留待测试断言同步后再包(结构冲突,见 i18n-2 记录)。
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<AppThemeMode>(
                  segments: const [
                    ButtonSegment(
                        value: AppThemeMode.system, label: Text('跟随系统')),
                    ButtonSegment(
                        value: AppThemeMode.light, label: Text('浅色')),
                    ButtonSegment(
                        value: AppThemeMode.dark, label: Text('深色')),
                  ],
                  selected: {controller.settings.themeMode},
                  onSelectionChanged: (s) =>
                      controller.setThemeMode(s.first),
                ),
              ),
              ListTile(
                title: Text(context.t('语言')),
                subtitle: Text(context.t('界面文案语言;默认中文,可跟随系统')),
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
                title: Text(context.t('自动传输(速传)')),
                subtitle: Text(context.t('连接期间相机新拍的照片自动下载并导入相册')),
                value: controller.settings.autoTransfer,
                onChanged: controller.setAutoTransfer,
              ),
              ListTile(
                title: Text(context.t('速传格式')),
                subtitle: Text(context.t(
                    '双格式(RAW+JPG)照片按此选择下载哪个;「仅视频」只速传视频')),
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
              ListTile(
                title: Text(context.t('元数据注入(XMP)')),
                subtitle: Text(
                    context.t('下载 JPG 时写入版权/作者/评分/位置(仅影响本机副本)')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _creatorCtrl,
                  focusNode: _creatorFocus,
                  decoration: InputDecoration(
                    labelText: context.t('作者(dc:creator)'),
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
                    labelText: context.t('版权(dc:rights)'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: controller.setXmpRights,
                ),
              ),
              SwitchListTile(
                title: Text(context.t('写入评分')),
                subtitle: Text(context.t('已打星的照片把星级写入 xmp:Rating')),
                value: controller.settings.xmpInjectRating,
                onChanged: controller.setXmpInjectRating,
              ),
              SwitchListTile(
                title: Text(context.t('写入位置(GPS)')),
                subtitle: Text(context.t('下载时取当前位置写入 EXIF GPS(需定位权限)')),
                value: controller.settings.xmpInjectGps,
                onChanged: controller.setXmpInjectGps,
              ),
              const Divider(),
              ListTile(
                title: Text(context.t('水印')),
                subtitle: Text(context.t('下载 JPG 时合成:角标或摄影卡片(EXIF 卡)')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<WatermarkStyle>(
                  segments: [
                    ButtonSegment(
                        value: WatermarkStyle.off,
                        label: Text(context.t('关闭'))),
                    ButtonSegment(
                        value: WatermarkStyle.corner,
                        label: Text(context.t('角标'))),
                    ButtonSegment(
                        value: WatermarkStyle.card,
                        label: Text(context.t('摄影卡'))),
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
                      labelText: context.t('水印文本(空 = 相机型号)'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: controller.setWatermarkText,
                  ),
                ),
              const Divider(),
              ListTile(
                title: Text(context.t('监看')),
                subtitle: Text(context.t('取景画面显示层处理:上采样 / 降噪 / 旋转 / 变宽')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(context.t('画面上采样'),
                      style: const TextStyle(fontSize: 13)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<FeedUpscaler>(
                  segments: [
                    ButtonSegment(
                        value: FeedUpscaler.off, label: Text(context.t('关'))),
                    ButtonSegment(
                        value: FeedUpscaler.fast, label: Text(context.t('快速'))),
                    ButtonSegment(
                        value: FeedUpscaler.quality,
                        label: Text(context.t('高质量'))),
                  ],
                  selected: {controller.settings.feedUpscaler},
                  onSelectionChanged: (s) =>
                      controller.setFeedUpscaler(s.first),
                ),
              ),
              SwitchListTile(
                title: Text(context.t('时域降噪')),
                subtitle: Text(
                    context.t('前后帧运动自适应混合(仅「高质量」上采样生效)')),
                value: controller.settings.temporalDenoise,
                onChanged: controller.setTemporalDenoise,
              ),
              SwitchListTile(
                title: Text(context.t('画面自动旋转')),
                subtitle: Text(context.t('相机竖持/倒置时画面转正显示(默认开)')),
                value: controller.settings.autoRotateFeed,
                onChanged: controller.setAutoRotateFeed,
              ),
              ListTile(
                title: Text(context.t('变宽还原(anamorphic)')),
                subtitle: Text(context.t('变形宽银幕镜头的水平挤压按倍率还原显示;当前 {v}×',
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
                            ? Text(context.t('关'))
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
                title: Text(context.t('传输质量')),
                subtitle: Text(context.t('原图直传(压缩传输待后续版本)')),
                enabled: false,
              ),
              ListTile(
                title: Text(context.t('BLE 配对 / GPS 注入')),
                subtitle: Text(
                    context.t('相机智能设备模式配对;拍进卡的照片原生带 EXIF 坐标')),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const BlePairPage()),
                ),
              ),
              buildSnapshotSection(context),
            ],
          ),
        ),
      ),
    );
  }
}
