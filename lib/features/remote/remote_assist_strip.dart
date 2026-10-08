import 'package:flutter/material.dart';

import 'live_design.dart';
import 'monitor_toggles.dart';
import 'remote_controller.dart';

/// 辅助开关组(竖屏底部整条 / 横屏浮层面板共用):监看开关 Wrap +
/// 对焦后拍/自拍/APP 接管芯片。状态随控制器 + [toggles](页面级视图
/// 偏好),监听由外层 AnimatedBuilder 驱动;开关变化经
/// [onTogglesChanged] 回页面(页面 setState + 同步帧分析器启停)。
/// 颜色随应用主题(LiveDesign.of)。
Widget _assistToggles(
  BuildContext context, {
  required RemoteController controller,
  required MonitorToggles toggles,
  required void Function(MonitorToggles) onTogglesChanged,
  required void Function(BuildContext) onTakeoverRequest,
}) {
  final live = LiveDesign.of(context);
  Widget toggle(IconData icon, String label, bool current,
      void Function(bool) set) {
    // 命中区 ≥44×44(视觉盒 40×34 不变,标签纳入点击):InkWell 包住
    // 整列再垫透明 padding;外层不画水波/高亮 —— 视觉零变化。
    return InkWell(
      onTap: () => set(!current),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 34,
              child: Material(
                color: current ? live.accentDim : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: current
                        ? live.accent.withValues(alpha: 0.5)
                        : live.hairline,
                  ),
                ),
                child: InkWell(
                  onTap: () => set(!current),
                  customBorder: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon,
                      size: 18,
                      color: current ? live.accent : live.muted),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    color: current ? live.accent : live.faint)),
          ],
        ),
      ),
    );
  }

  return Wrap(
    spacing: 2,
    runSpacing: 4,
    children: [
      toggle(Icons.grid_on, '网格', toggles.grid,
          (v) => onTogglesChanged(toggles.copyWith(grid: v))),
      // 四个分析类开关改完须同步分析器启停(共享一份帧分析;
      // 开而分析器未启 = 直方图无数据一类静默失效)—— 同步在页面的
      // onTogglesChanged 里统一做。
      toggle(Icons.warning_amber, '斑马纹', toggles.zebra,
          (v) => onTogglesChanged(toggles.copyWith(zebra: v))),
      toggle(Icons.bar_chart, '直方图', toggles.histogram,
          (v) => onTogglesChanged(toggles.copyWith(histogram: v))),
      toggle(Icons.linear_scale, '水平仪', toggles.level,
          (v) => onTogglesChanged(toggles.copyWith(level: v))),
      toggle(Icons.palette_outlined, '伪色', toggles.falseColor,
          (v) => onTogglesChanged(toggles.copyWith(falseColor: v))),
      toggle(Icons.blur_on, '峰值', toggles.peaking,
          (v) => onTogglesChanged(toggles.copyWith(peaking: v))),
      const SizedBox(width: 6),
      _smallChip(
        live: live,
        label: '对焦后拍',
        selected: controller.focusBeforeCapture,
        onTap: () => controller.focusBeforeCapture =
            !controller.focusBeforeCapture,
        tooltip: '释放快门前先自动对焦(半按-全按;候选参数,待真机核对)',
      ),
      Builder(
        // Builder 让 showMenu 锚到自拍芯片本身(而非整条辅助条)。
        builder: (chipContext) => _smallChip(
          live: live,
          label: controller.selfTimerSeconds == 0
              ? '自拍'
              : '自拍 ${controller.selfTimerSeconds}s',
          selected: controller.selfTimerSeconds > 0,
          onTap: () => _pickSelfTimer(chipContext, controller),
          tooltip: '自拍定时:关/2s/5s/10s 点选;倒计时中再点取消',
        ),
      ),
      _takeoverChip(context,
          controller: controller, onTakeoverRequest: onTakeoverRequest),
    ],
  );
}

/// 竖屏底部辅助条:监看开关 + 对焦后拍/自拍/APP 接管芯片。
class RemoteAssistStrip extends StatelessWidget {
  const RemoteAssistStrip({
    super.key,
    required this.controller,
    required this.toggles,
    required this.onTogglesChanged,
    required this.onTakeoverRequest,
    this.margin,
  });

  final RemoteController controller;
  final MonitorToggles toggles;
  final void Function(MonitorToggles toggles) onTogglesChanged;
  final void Function(BuildContext context) onTakeoverRequest;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: live.hairline),
      ),
      child: _assistToggles(context,
          controller: controller,
          toggles: toggles,
          onTogglesChanged: onTogglesChanged,
          onTakeoverRequest: onTakeoverRequest),
    );
  }
}

/// 横屏辅助浮层(非模态):监看开关 + 芯片组,锚在顶栏 tune 钮下方、
/// 让位右动作栏。点取景画面即收起(见 RemotePage._handleTapFocus),
/// 点浮层外的其他控制件不收 —— 浮层不遮它们,互不打扰。
class RemoteAssistPanel extends StatelessWidget {
  const RemoteAssistPanel({
    super.key,
    required this.controller,
    required this.toggles,
    required this.onTogglesChanged,
    required this.onTakeoverRequest,
  });

  final RemoteController controller;
  final MonitorToggles toggles;
  final void Function(MonitorToggles toggles) onTogglesChanged;
  final void Function(BuildContext context) onTakeoverRequest;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: live.hairline),
      ),
      child: _assistToggles(context,
          controller: controller,
          toggles: toggles,
          onTogglesChanged: onTogglesChanged,
          onTakeoverRequest: onTakeoverRequest),
    );
  }
}

/// 辅助条小芯片(对焦后拍 / 自拍 / APP 接管)。
Widget _smallChip({
  required LivePalette live,
  required String label,
  required bool selected,
  required VoidCallback? onTap,
  String? tooltip,
}) {
  final chip = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Material(
      color: selected ? live.accentDim : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color: selected
                ? live.accent.withValues(alpha: 0.5)
                : live.hairline),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
                fontSize: 12,
                color: selected ? live.accent : live.muted),
          ),
        ),
      ),
    ),
  );
  return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
}

/// APP 接管控制状态芯片:未接管 = 点按弹确认启用;已接管 = 点按解除
/// (0x90C2 remote 模式;机身拨盘锁定,host 写入保值)。
Widget _takeoverChip(BuildContext context,
    {required RemoteController controller,
    required void Function(BuildContext) onTakeoverRequest}) {
  final live = LiveDesign.of(context);
  final active = controller.takeoverActive;
  return _smallChip(
    live: live,
    label: active ? 'APP 接管中' : 'APP 接管',
    selected: active,
    onTap: !controller.linkUp
        ? null
        : (active
            ? controller.releaseTakeover
            : () => onTakeoverRequest(context)),
    tooltip: '拨盘级参数(快门/模式/ISO/光圈)需先接管才能遥控调整',
  );
}

/// 自拍档位点选(芯片 → 菜单):关/2s/5s/10s 单选,当前档打勾;
/// 倒计时中点按 = 取消当前倒计时(同档重设即取消,见 setSelfTimer)。
/// 菜单颜色随应用主题。
Future<void> _pickSelfTimer(
    BuildContext chipContext, RemoteController controller) async {
  if (controller.selfTimerCountdown != null) {
    controller.setSelfTimer(controller.selfTimerSeconds);
    return;
  }
  final live = LiveDesign.of(chipContext);
  final box = chipContext.findRenderObject() as RenderBox?;
  final overlay =
      Navigator.of(chipContext).overlay?.context.findRenderObject()
          as RenderBox?;
  if (box == null || overlay == null) return;
  final value = await showMenu<int>(
    context: chipContext,
    color: live.surface,
    position: RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final s in const [0, 2, 5, 10])
        PopupMenuItem<int>(
          value: s,
          child: Row(
            children: [
              Text(s == 0 ? '关' : '$s 秒',
                  style: TextStyle(fontSize: 14, color: live.text)),
              if (s == controller.selfTimerSeconds) ...[
                const Spacer(),
                Icon(Icons.check, size: 18, color: live.accent),
              ],
            ],
          ),
        ),
    ],
  );
  if (value != null) controller.setSelfTimer(value);
}
