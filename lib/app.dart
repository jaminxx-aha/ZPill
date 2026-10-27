import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_services.dart';
import 'config/app_brand.dart';
import 'data/settings_store.dart';
import 'design/app_theme.dart';
import 'features/shell/home_shell.dart';
import 'l10n/l10n.dart';

/// 应用根。
///
/// 结构:底部导航三 tab(相机 / 图库 / 设置,见 HomeShell);拍摄页
/// 由相机页已连接视图「进入拍摄」全屏 push 进入。主题:品牌黄画布双套
/// (见 design/),默认跟随系统深浅,设置页可锁浅色/深色(themeMode 由
/// SettingsController 驱动,选中即存);拍摄页外围 chrome 随主题、取景
/// 画面内容层恒暗(LiveDesign)。
///
/// 语言(i18n 抽象键制):[L10nScope] 挂在 MaterialApp 外层(builder 直
/// 返回值,设置改动沿 ListenableBuilder 每次重建重装)—— pushed 路由
/// (拍摄页/相机相册/查看器/编辑页)与 dialog 都在 Navigator 之下、不在
/// home 子树内,scope 若只包 home 会漏掉整条 push 栈。**scope 才是 t()
/// 的唯一语言来源**;MaterialApp 的 locale/supportedLocales/delegates
/// 只喂框架组件(菜单/日期选择等内置文案)。
class ZPillApp extends StatelessWidget {
  const ZPillApp({super.key});

  /// 语言设置 → t() 消费的语言码('zh'/'en',已解析,**不存在 system
  /// 态**)。跟随系统在此自解析(非 en 一律落中文,与 supportedLocales
  /// 首位 zh 同口径),**不依赖 MaterialApp 的 localeResolutionCallback**
  /// —— scope 与 locale 是两条并行消费路,解析各自收口。
  static String _l10nCodeOf(AppLanguage language) => switch (language) {
        AppLanguage.zh => 'zh',
        AppLanguage.en => 'en',
        AppLanguage.system =>
          WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'en'
              ? 'en'
              : 'zh',
      };

  @override
  Widget build(BuildContext context) {
    final controller = AppServices.instance.settingsController;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => L10nScope(
        code: _l10nCodeOf(controller.settings.language),
        child: MaterialApp(
          // 水平安全区 + 显示特性清零:这台机曲面屏的安全区/圆角显示
          // 特性会把 MenuAnchor 面板钳在距右缘 ~27px 处(_positionChild
          // 的 avoidBounds 钳制),应用内容本就近边绘制 —— 清零后弹层
          // 缝隙由 open(position:) 精确控制(4px)。
          //
          // textScaler 钉统一系数:系统动态字号只缩放 Text 不缩 Icon/
          // 布局,平台字号档不同时同一份代码双端大小/折行全错位(设置
          // 页实证)。系数 = iOS 端系统字号档实测值(标题/正文两线互证
          // 0.83/0.85),以 iOS 观感为基准 —— iPhone 端不变,其余平台
          // 对齐;网格角标格内另有绝对钉(见 media_grid),不受此影响。
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: MediaQuery.of(context).padding.copyWith(
                    left: 0,
                    right: 0,
                  ),
              displayFeatures: const [],
              textScaler: const TextScaler.linear(0.85),
            ),
            child: child!,
          ),
          title: AppBrand.displayName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: switch (controller.settings.themeMode) {
            AppThemeMode.system => ThemeMode.system,
            AppThemeMode.light => ThemeMode.light,
            AppThemeMode.dark => ThemeMode.dark,
          },
          // 只喂框架组件内置文案:system → null 交给系统解析
          // (supportedLocales 首位 zh = 系统语言不受支持时落中文)。
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          locale: switch (controller.settings.language) {
            AppLanguage.system => null,
            AppLanguage.zh => const Locale('zh'),
            AppLanguage.en => const Locale('en'),
          },
          home: const HomeShell(),
        ),
      ),
    );
  }
}
