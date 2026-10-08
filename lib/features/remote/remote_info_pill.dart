import 'package:flutter/material.dart';

import 'live_design.dart';
import 'remote_controller.dart';

/// 信息胶囊:返回钮(路由态)+ 链路点 + 设备名 + 剩余张数/REC 时长 +
/// 接管徽标 + 监看辅助浮层钮(竖屏)+ 方向钮(链路/设备状态随控制器,
/// 监听由外层 AnimatedBuilder 驱动)。
///
/// [compact]:横屏顶栏态 —— 不占满宽(收缩包内容,顶栏中部透出
/// 画面),徽标前用小间距代替 Spacer 撑开。
class RemoteInfoPill extends StatelessWidget {
  const RemoteInfoPill({
    super.key,
    required this.controller,
    required this.onToggleOrientation,
    this.onToggleAssist,
    this.assistSelected = false,
    this.margin,
    this.compact = false,
  });

  final RemoteController controller;
  final VoidCallback onToggleOrientation;

  /// 监看辅助浮层入口(竖屏胶囊内 tune 钮)。null = 不渲染 —— 横屏
  /// 顶栏自带 ChromeIconButton 同职入口,胶囊里不重复。
  final VoidCallback? onToggleAssist;

  /// [onToggleAssist] 的选中态(浮层展开时金高亮)。
  final bool assistSelected;

  final EdgeInsetsGeometry? margin;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final linked = controller.linkUp;
    final name = controller.connection?.deviceName;
    // 返回钮只在路由态出现:拍摄页从底栏 tab 改为相机页 push 进入
    // (2026-10-08),页内无 AppBar,这里补返回入口;直挂首页/单测里
    // canPop 为假则不占位(系统返回手势照常可用,这里只是显式入口)。
    final canPop = Navigator.of(context).canPop();
    return Container(
      width: compact ? null : double.infinity,
      margin: margin ?? const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: live.hairline),
      ),
      child: Row(
        children: [
          if (canPop) ...[
            _backButton(context, live),
            const SizedBox(width: 2),
          ],
          Icon(Icons.circle,
              size: 8, color: linked ? live.good : live.bad),
          const SizedBox(width: 8),
          // 横屏顶栏与辅助条分宽,名字可能被挤 —— 省略号收尾
          Flexible(
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
          compact ? const SizedBox(width: 12) : const Spacer(),
          if (controller.takeoverActive) ...[
            Icon(Icons.lock, size: 13, color: live.accent),
            const SizedBox(width: 4),
            Text('APP 接管中',
                style: TextStyle(fontSize: 12, color: live.accent)),
            const SizedBox(width: 6),
          ],
          if (onToggleAssist != null) ...[
            _assistButton(live),
            const SizedBox(width: 2),
          ],
          _orientationButton(live),
        ],
      ),
    );
  }

  /// 返回钮(行首,路由态):pop 回相机页。与方向钮同款胶囊内嵌
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

  /// 监看辅助浮层开关钮(方向钮左侧,竖屏排版):tune 图标,展开态金
  /// 高亮;与返回/方向钮同款胶囊内嵌 InkWell(34×30 触达、9 圆角)。
  Widget _assistButton(LivePalette live) {
    return InkWell(
      onTap: onToggleAssist,
      customBorder:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      child: SizedBox(
        width: 34,
        height: 30,
        child: Icon(Icons.tune,
            size: 18, color: assistSelected ? live.accent : live.muted),
      ),
    );
  }

  /// 方向切换钮(信息胶囊行尾,竖横屏同位一处实现):**恒显转屏图标**
  /// —— 不随锁态换形(stay_current_*/crop_* 两轮换形实测 18px 金色下
  /// 均不可辨,用户明示「一直用最初始的图标」,2026-10-08);**无
  /// Tooltip**(其长按弹「已锁xx」提示被用户点名单删)。点按横↔竖
  /// 直切,锁态只在控制器里流转(会话级),页面重建不丢。
  Widget _orientationButton(LivePalette live) {
    return InkWell(
      onTap: onToggleOrientation,
      customBorder:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      child: SizedBox(
        width: 34,
        height: 30,
        child: Icon(Icons.screen_rotation, size: 18, color: live.muted),
      ),
    );
  }
}

/// 录制时长标签(m:ss;展示就近取值,事件/交互驱动刷新)。
String recDurationLabel(int? seconds) {
  final s = seconds ?? 0;
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}
