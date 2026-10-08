import 'package:flutter/material.dart';

import 'app_services.dart';
import 'data/settings_store.dart';
import 'design/app_theme.dart';
import 'features/shell/home_shell.dart';

/// 应用根。
///
/// 结构:底部导航三 tab(相机 / 图库 / 设置,见 HomeShell);拍摄页
/// 由相机页已连接视图「进入拍摄」全屏 push 进入。主题:品牌黄画布双套
/// (见 design/),默认跟随系统深浅,设置页可锁浅色/深色(themeMode 由
/// SettingsController 驱动,选中即存);拍摄页外围 chrome 随主题、取景
/// 画面内容层恒暗(LiveDesign)。
class NikonPillApp extends StatelessWidget {
  const NikonPillApp({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppServices.instance.settingsController;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        title: 'NikonPill',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: switch (controller.settings.themeMode) {
          AppThemeMode.system => ThemeMode.system,
          AppThemeMode.light => ThemeMode.light,
          AppThemeMode.dark => ThemeMode.dark,
        },
        home: const HomeShell(),
      ),
    );
  }
}
