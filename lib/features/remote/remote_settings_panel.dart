import 'package:flutter/material.dart';

import 'live_design.dart';
import 'monitor_toggles.dart';
import 'remote_capture_strip.dart';
import 'remote_controller.dart';
import 'shooting_param_catalog.dart';

/// 拍摄设置浮层(2026-10-10 iPhone 相机式重排:控制行「设置」钮的非
/// 模态玻璃浮层,竖屏底锚居中/横屏让位右缘快门柱;吸收原「监看辅助」
/// 浮层 —— tune 钮由胶囊/顶栏移到控制行):四段 —— ①拍摄参数(全
/// 目录 tile,点按走 [onEditParam] → 参数编辑底单;2026-10-12 竖屏
/// 读出行与横屏左参数栏先后删除后成为唯一参数入口)②对焦
/// (2026-10-12 自对焦浮层迁入:MF 步进/拉焦轮 —— 快门旁对焦钮已瘦身
/// 为一键 AF)③监看开关(网格/斑马纹/直方图/水平仪/伪色/峰值)④辅
/// 助芯片(对焦后拍/自拍/APP 接管)。[maxHeight] 限高内滚(竖屏约
/// 0.55 屏高,横屏顶栏与底条之间);点取景画面或再点设置钮即收(见
/// RemotePage);状态随控制器 + [toggles](页面级视图偏好),监听由
/// 外层 AnimatedBuilder 驱动。
class CaptureSettingsPanel extends StatelessWidget {
  const CaptureSettingsPanel({
    super.key,
    required this.controller,
    required this.toggles,
    required this.activeParam,
    required this.onEditParam,
    required this.onTogglesChanged,
    required this.onTakeoverRequest,
    this.maxHeight,
  });

  final RemoteController controller;
  final MonitorToggles toggles;

  /// 当前打开编辑底单的参数码(金高亮 tile,读出条同款联动)。
  final int? activeParam;

  final void Function(BuildContext context, ShootingParam param) onEditParam;
  final void Function(MonitorToggles toggles) onTogglesChanged;
  final void Function(BuildContext context) onTakeoverRequest;

  /// 内容限高(null = 不限);超出内部滚动。
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final body = SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(live, '拍摄参数'),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final p in orderedCaptureParams())
                  captureParamTileOf(
                      context, controller, activeParam, onEditParam, p),
              ],
            ),
            _sectionHeader(live, '对焦'),
            _focusControls(context),
            _sectionHeader(live, '监看'),
            _monitorToggles(context),
            _sectionHeader(live, '辅助'),
            _assistChips(context),
          ],
        ),
      ),
    );
    return Container(
      constraints: maxHeight == null
          ? null
          : BoxConstraints(maxHeight: maxHeight!),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: live.hairline),
      ),
      child: body,
    );
  }

  Widget _sectionHeader(LivePalette live, String label) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: live.faint)),
      );

  /// 对焦控制组(2026-10-12 自对焦浮层迁入):MF 步进(0x9204 相对量,
  /// 近/远各一步)+ 拉焦轮开关(取景画面右缘竖条,开 = 金;重开清失败
  /// 预算 resetFocusDial,从可用态起步)。机身对焦模式为 MF 时全部灰化
  /// (机内马达脱开,远程对焦失效 —— 只有镜头对焦环能动焦)+ 常驻提示
  /// 行(盲按无响应的困惑根源)。
  Widget _focusControls(BuildContext context) {
    final live = LiveDesign.of(context);
    final usable = controller.linkUp &&
        controller.liveViewActive &&
        !controller.focusModeIsMf;
    Widget step(IconData icon, bool towardNear, String label, String tip) {
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: usable ? () => controller.mfDriveStep(towardNear: towardNear) : null,
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
                    color: live.glass,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: live.hairline),
                    ),
                    child: InkWell(
                      onTap: usable
                          ? () =>
                              controller.mfDriveStep(towardNear: towardNear)
                          : null,
                      customBorder: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      child: Icon(icon,
                          size: 18, color: usable ? live.text : live.faint),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(fontSize: 10, color: live.faint)),
              ],
            ),
          ),
        ),
      );
    }

    final dialOn = toggles.focusDial;
    Widget dialToggle = InkWell(
      onTap: () {
        if (!dialOn) controller.resetFocusDial();
        onTogglesChanged(toggles.copyWith(focusDial: !dialOn));
      },
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
                color: dialOn ? live.accentDim : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: dialOn
                        ? live.accent.withValues(alpha: 0.5)
                        : live.hairline,
                  ),
                ),
                child: Icon(Icons.vertical_align_center,
                    size: 18, color: dialOn ? live.accent : live.muted),
              ),
            ),
            const SizedBox(height: 2),
            Text('拉焦轮',
                style: TextStyle(
                    fontSize: 10, color: dialOn ? live.accent : live.faint)),
          ],
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 2,
          runSpacing: 4,
          children: [
            step(Icons.remove, true, 'MF 近', 'MF 向近(步进)'),
            step(Icons.add, false, 'MF 远', 'MF 向远(步进)'),
            dialToggle,
          ],
        ),
        if (controller.focusModeIsMf) ...[
          const SizedBox(height: 6),
          Text('机身对焦模式为 MF,远程对焦已停用',
              style: TextStyle(fontSize: 10, color: live.muted)),
        ],
      ],
    );
  }

  /// 监看开关组(原辅助浮层迁移,拉焦轮除外 —— 在上方对焦段):斑马纹/
  /// 直方图/伪色/峰值四项共享一份帧分析 —— 开关落定后由页面同步
  /// RemoteController.analyzer 启停(见 RemotePage._syncAnalyzerEnabled)。
  Widget _monitorToggles(BuildContext context) {
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
      ],
    );
  }

  /// 辅助芯片组(原辅助浮层迁移):对焦后拍 / 自拍 / APP 接管。
  Widget _assistChips(BuildContext context) {
    return Wrap(
      spacing: 2,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _smallChip(
          live: LiveDesign.of(context),
          label: '对焦后拍',
          selected: controller.focusBeforeCapture,
          onTap: () => controller.focusBeforeCapture =
              !controller.focusBeforeCapture,
          tooltip: '释放快门前先自动对焦(半按-全按;候选参数,待真机核对)',
        ),
        Builder(
          // Builder 让 showMenu 锚到自拍芯片本身(而非整条浮层)。
          builder: (chipContext) => _smallChip(
            live: LiveDesign.of(chipContext),
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
}

/// 浮层小芯片(对焦后拍 / 自拍 / APP 接管)。
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
                fontSize: 12, color: selected ? live.accent : live.muted),
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
