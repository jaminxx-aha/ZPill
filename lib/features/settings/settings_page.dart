/// 设置页(TODO.md §五):深浅模式/速传开关/格式,后续 T4 段位(水印/
/// LUT)再扩。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../data/settings_store.dart';
import 'snapshot_controller.dart' show buildSnapshotSection;

class SettingsController extends ChangeNotifier {
  SettingsController({required this.store}) {
    _sub = store.settings.listen((s) {
      settings = s;
      notifyListeners();
    });
    unawaited(_load());
  }

  final SettingsStore store;
  AppSettings settings = const AppSettings();
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
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => GestureDetector(
          // 点空白散焦收键盘:文本框自身的点按由它的手势竞技场赢下,不冲突
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              ListTile(
                title: const Text('深色模式'),
                subtitle: const Text('跟随系统,或锁定浅色/深色'),
              ),
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
              const Divider(),
              SwitchListTile(
                title: const Text('自动传输(速传)'),
                subtitle: const Text('连接期间相机新拍的照片自动下载并导入相册'),
                value: controller.settings.autoTransfer,
                onChanged: controller.setAutoTransfer,
              ),
              ListTile(
                title: const Text('速传格式'),
                subtitle: const Text('双格式(RAW+JPG)照片按此选择下载哪个;「仅视频」只速传视频'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<PhotoDownloadFormat>(
                  segments: [
                    for (final f in PhotoDownloadFormat.values)
                      ButtonSegment(value: f, label: Text(f.short)),
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
                title: const Text('元数据注入(XMP)'),
                subtitle: const Text('下载 JPG 时写入版权/作者/评分/位置(仅影响本机副本)'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _creatorCtrl,
                  focusNode: _creatorFocus,
                  decoration: const InputDecoration(
                    labelText: '作者(dc:creator)',
                    border: OutlineInputBorder(),
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
                  decoration: const InputDecoration(
                    labelText: '版权(dc:rights)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: controller.setXmpRights,
                ),
              ),
              SwitchListTile(
                title: const Text('写入评分'),
                subtitle: const Text('已打星的照片把星级写入 xmp:Rating'),
                value: controller.settings.xmpInjectRating,
                onChanged: controller.setXmpInjectRating,
              ),
              SwitchListTile(
                title: const Text('写入位置(GPS)'),
                subtitle: const Text('下载时取当前位置写入 EXIF GPS(需定位权限)'),
                value: controller.settings.xmpInjectGps,
                onChanged: controller.setXmpInjectGps,
              ),
              const Divider(),
              ListTile(
                title: const Text('水印'),
                subtitle: const Text('下载 JPG 时合成:角标或摄影卡片(EXIF 卡)'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<WatermarkStyle>(
                  segments: const [
                    ButtonSegment(value: WatermarkStyle.off, label: Text('关闭')),
                    ButtonSegment(
                        value: WatermarkStyle.corner, label: Text('角标')),
                    ButtonSegment(
                        value: WatermarkStyle.card, label: Text('摄影卡')),
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
                    decoration: const InputDecoration(
                      labelText: '水印文本(空 = 相机型号)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: controller.setWatermarkText,
                  ),
                ),
              const Divider(),
              const ListTile(
                title: Text('传输质量'),
                subtitle: Text('原图直传(压缩传输待后续版本)'),
                enabled: false,
              ),
              buildSnapshotSection(context),
            ],
          ),
        ),
      ),
    );
  }
}
