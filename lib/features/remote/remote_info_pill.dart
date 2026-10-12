import 'package:flutter/material.dart';

import 'live_design.dart';
import 'remote_controller.dart';

/// 信息胶囊:返回钮(路由态)+ 链路点 + 设备名 + 剩余张数/REC 时长 +
/// 接管徽标 + 纯净监看隐藏钮(竖屏;链路/设备状态随控制器,监听由外层
/// AnimatedBuilder 驱动)。2026-10-10 iPhone 相机式重排:方向钮移底部
/// 控制行、监看辅助 tune 钮移设置浮层入口,胶囊只余隐藏钮(横屏顶栏
/// 自带 ChromeIconButton 同职,[onHideChrome] 传 null 即不渲染);
/// 隐藏后恢复钮出现在**同一处**(页面在右上角同位摆恢复钮)。
///
/// [compact]:横屏顶栏态(2026-10-12 胶囊整体居中)—— 收缩包内容
/// (mainAxisSize.min,名字 Flexible 而非 Expanded)可被 Center 居中,
/// 徽标前用小间距代替 Spacer 撑开;非 compact 照旧占满宽、行尾恒贴
/// 右缘(2026-10-10 修 Flexible→Expanded 的同款口径)。[fixedWidth]:
/// 九轮「上方的按钮长一点约为两倍」—— 横屏定宽
/// ([kLandscapePillWidth]);**内部与非 compact 同构**(十一轮用户定案
/// 「横屏时上方的 button 里面的参数位置和竖屏保持一致」:名字
/// Expanded + Spacer 各分一半余量 → 张数/REC 落名后中带、隐藏钮恒贴
/// 行尾,同竖屏观感)。
class RemoteInfoPill extends StatelessWidget {
  const RemoteInfoPill({
    super.key,
    required this.controller,
    this.onHideChrome,
    this.margin,
    this.compact = false,
    this.fixedWidth,
  });

  final RemoteController controller;

  /// 纯净监看入口(竖屏胶囊行尾):null = 不渲染 —— 横屏顶栏自带
  /// ChromeIconButton 同职入口,胶囊里不重复。
  final VoidCallback? onHideChrome;

  final EdgeInsetsGeometry? margin;
  final bool compact;

  /// 定宽(横屏顶栏,九轮):null = 照旧(compact 收缩包 / 非 compact
  /// 占满宽);非 null 时胶囊取此宽,内部 Spacer 拉开行尾贴右。
  final double? fixedWidth;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final linked = controller.linkUp;
    final name = controller.connection?.deviceName;
    // 返回钮只在路由态出现:拍摄页从底栏 tab 改为相机页 push 进入
    // (2026-10-08),页内无 AppBar,这里补返回入口;直挂首页/单测里
    // canPop 为假则不占位(系统返回手势照常可用,这里只是显式入口)。
    final canPop = Navigator.of(context).canPop();
    final wide = fixedWidth != null;
    return Container(
      width: fixedWidth ?? (compact ? null : double.infinity),
      margin: margin ?? const EdgeInsets.fromLTRB(12, 8, 12, 4),
      // 十轮:横屏(compact)竖直 padding 7→4 → 胶囊高 38,与贴底
      // 模式条同高(用户「改成一致,和底部一致」);竖屏照旧 44。
      padding: EdgeInsets.symmetric(
          horizontal: 12, vertical: compact ? 4 : 7),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: live.hairline),
      ),
      child: Row(
        // compact 收缩包内容(横屏胶囊居中的前提);非 compact 占满宽
        // (Container width infinity 的紧约束下 min/max 同果,行尾贴右)。
        // 定宽时取 max:余量交给 Spacer,隐藏钮贴行尾(九轮)。
        mainAxisSize: compact && !wide
            ? MainAxisSize.min
            : MainAxisSize.max,
        children: [
          if (canPop) ...[
            _backButton(context, live),
            const SizedBox(width: 2),
          ],
          Icon(Icons.circle,
              size: 8, color: linked ? live.good : live.bad),
          const SizedBox(width: 8),
          // 横屏顶栏与浮层分宽,名字可能被挤 —— 省略号收尾。非 compact
          // 用 Expanded 吃满余量:行尾徽标/隐藏钮恒贴右缘(旧 Flexible+
          // Spacer 各分一半自由空间,短设备名时行尾钮悬在半行 ——
          // 2026-10-10 隐藏/恢复同位需求暴露);compact 收缩包用
          // Flexible(名字取内在宽,超限省略);**定宽时与非 compact
          // 同构也用 Expanded**(十一轮用户定案「横屏上方的 button
          // 里面的参数位置和竖屏保持一致」—— Expanded+Spacer 各分一半
          // 余量,张数/REC 落名后中带、行尾钮恒贴右,同竖屏观感)。
          compact && !wide
              ? Flexible(
                  child: Text(
                    linked ? (name ?? '已连接') : '未连接相机',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: live.text),
                  ),
                )
              : Expanded(
                  child: Text(
                    linked ? (name ?? '已连接') : '未连接相机',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: live.text),
                  ),
                ),
          if (linked && controller.shotsRemaining != null) ...[
            const SizedBox(width: 10),
            Text('${controller.shotsRemaining} 张',
                style: TextStyle(
                    fontSize: 12,
                    color: live.muted,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
          if (controller.recording) ...[
            const SizedBox(width: 10),
            Icon(Icons.circle, size: 8, color: live.bad),
            const SizedBox(width: 4),
            Text('REC ${recDurationLabel(controller.recordingSeconds)}',
                style: TextStyle(
                    fontSize: 12,
                    color: live.bad,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
          // 定宽时余量全归 Spacer(隐藏钮贴行尾,九轮);收缩包时小间距。
          compact && !wide
              ? const SizedBox(width: 12)
              : const Spacer(),
          if (controller.takeoverActive) ...[
            Icon(Icons.lock, size: 13, color: live.accent),
            const SizedBox(width: 4),
            Text('APP 接管中',
                style: TextStyle(fontSize: 12, color: live.accent)),
            const SizedBox(width: 6),
          ],
          if (onHideChrome != null) ...[
            _hideButton(live),
            const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }

  /// 返回钮(行首,路由态):pop 回相机页。与隐藏钮同款胶囊内嵌
  /// InkWell(34×30 触达、9 圆角)。
  Widget _backButton(BuildContext context, LivePalette live) {
    return InkWell(
      onTap: () => Navigator.of(context).maybePop(),
      customBorder:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      child: SizedBox(
        width: 34,
        height: 30,
        child: Icon(Icons.arrow_back, size: 18, color: live.muted),
      ),
    );
  }

  /// 纯净监看隐藏钮(行尾,竖屏排版):眼睛划线图标,隐去全部控制
  /// 浮层;与返回钮同款胶囊内嵌 InkWell(34×30 触达、9 圆角)。恢复
  /// 钮由页面在隐藏后的右上角同位摆出(ChromeIconButton)。
  Widget _hideButton(LivePalette live) {
    return Tooltip(
      message: '纯净监看(隐藏全部控制,只留画面)',
      child: InkWell(
        onTap: onHideChrome,
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        child: SizedBox(
          width: 34,
          height: 30,
          child: Icon(Icons.visibility_off, size: 18, color: live.muted),
        ),
      ),
    );
  }
}

/// 录制时长标签(m:ss;展示就近取值,事件/交互驱动刷新)。REC 显示
/// 在胶囊里;拍摄页唯一直接消费方(2026-10-10 录制钮并入快门后)。
String recDurationLabel(int? seconds) {
  final s = seconds ?? 0;
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}
