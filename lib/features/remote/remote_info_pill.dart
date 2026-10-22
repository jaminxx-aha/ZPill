import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'live_design.dart';
import 'remote_controller.dart';

/// 信息胶囊:返回钮(路由态)+ 链路点 + 设备名 + 剩余张数/REC 时长 +
/// APP 接管钮(行尾;链路/设备状态随控制器,监听由外层 AnimatedBuilder
/// 驱动)。2026-10-17 用户定案:纯净监看隐藏钮撤除(隐藏/显示改点页面
/// 空白切换,见 RemotePage),行尾位由 APP 接管钮接替 —— 未接管 =
/// 点按弹确认启用([onTakeoverRequest]),已接管 = 点按解除;接管徽标
/// 并入钮态(lock_open 灰 = 未接管,lock 金 = 接管中)。
///
/// [compact]:横屏顶栏态(2026-10-12 胶囊整体居中)—— 收缩包内容
/// (mainAxisSize.min,名字 Flexible 而非 Expanded)可被 Center 居中,
/// 钮前用小间距代替 Spacer 撑开;非 compact 照旧占满宽、行尾恒贴
/// 右缘(2026-10-10 修 Flexible→Expanded 的同款口径)。[fixedWidth]:
/// 九轮「上方的按钮长一点约为两倍」—— 横屏定宽
/// ([kLandscapePillWidth]);**内部与非 compact 同构**(十一轮用户定案
/// 「横屏时上方的 button 里面的参数位置和竖屏保持一致」:名字
/// Expanded + Spacer 各分一半余量 → 张数/REC 落名后中带、接管钮恒贴
/// 行尾,同竖屏观感)。
class RemoteInfoPill extends StatelessWidget {
  const RemoteInfoPill({
    super.key,
    required this.controller,
    required this.onTakeoverRequest,
    this.margin,
    this.compact = false,
    this.fixedWidth,
  });

  final RemoteController controller;

  /// APP 接管确认入口(未接管点按弹「启用 APP 接管控制?」,页面侧
  /// [confirmTakeover] 同款对话框);已接管点按不走此回调,直接
  /// [RemoteController.releaseTakeover]。
  final void Function(BuildContext context) onTakeoverRequest;

  final EdgeInsetsGeometry? margin;
  final bool compact;

  /// 定宽(横屏顶栏,九轮):null = 照旧(compact 收缩包 / 非 compact
  /// 占满宽);非 null 时胶囊取此宽,内部 Spacer 拉开行尾贴右。
  final double? fixedWidth;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final linked = controller.linkUp;
    // 左上角只答「什么机型」不答「哪一台」(2026-10-17 用户定案:显
    // 型号 Zf,不显 Zf_序列号 —— 设备名留给相机页设备行)。
    final name = controller.connection?.deviceModel;
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
          // 用 Expanded 吃满余量:行尾接管钮恒贴右缘(旧 Flexible+
          // Spacer 各分一半自由空间,短设备名时行尾钮悬在半行 ——
          // 2026-10-10 隐藏/恢复同位需求暴露);compact 收缩包用
          // Flexible(名字取内在宽,超限省略);**定宽时与非 compact
          // 同构也用 Expanded**(十一轮用户定案「横屏上方的 button
          // 里面的参数位置和竖屏保持一致」—— Expanded+Spacer 各分一半
          // 余量,张数/REC 落名后中带、行尾钮恒贴右,同竖屏观感)。
          compact && !wide
              ? Flexible(
                  child: Text(
                    linked
                        ? (name ?? context.t('conn.connected'))
                        : context.t('remote.notConnected'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: live.text),
                  ),
                )
              : Expanded(
                  child: Text(
                    linked
                        ? (name ?? context.t('conn.connected'))
                        : context.t('remote.notConnected'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: live.text),
                  ),
                ),
          // 张数只在照片档出现(2026-10-16 探针定案):0xD1F1 ≡ 相机
          // 自报可拍,视频档被录像估算污染(隐含单张随档/画质游走,
          // 机身视频档也只显剩余时长不显张数),照搬出来是假张数。
          // 用户定案裸值:只显数字,不带「张」。
          if (linked &&
              controller.shotsRemaining != null &&
              controller.cameraMode != CaptureMode.video) ...[
            const SizedBox(width: 10),
            Text('${controller.shotsRemaining!}',
                style: TextStyle(
                    fontSize: 12,
                    color: live.muted,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
          // 视频档同位换剩余可录时长(帧头 @816 机身自报,与机身自家
          // 屏同口径);null = 头没带/本帧无效 → 不显,宁缺不错。
          // 用户定案裸显时间,不带「可录」前缀。
          if (linked &&
              controller.cameraMode == CaptureMode.video &&
              controller.videoRemainingMs != null) ...[
            const SizedBox(width: 10),
            Text(recRemainingLabel(controller.videoRemainingMs!),
                style: TextStyle(
                    fontSize: 12,
                    color: live.muted,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
          if (controller.recording) ...[
            const SizedBox(width: 10),
            Icon(Icons.circle, size: 8, color: live.bad),
            const SizedBox(width: 4),
            Text(
                '${context.t('remote.recPrefix')} '
                '${recDurationLabel(controller.recordingSeconds)}',
                style: TextStyle(
                    fontSize: 12,
                    color: live.bad,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
          // 定宽时余量全归 Spacer(接管钮贴行尾,九轮);收缩包时小间距。
          compact && !wide
              ? const SizedBox(width: 12)
              : const Spacer(),
          _takeoverButton(context, live),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  /// 返回钮(行首,路由态):pop 回相机页。与接管钮同款胶囊内嵌
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

  /// APP 接管钮(行尾,原纯净监看隐藏钮位,2026-10-17 用户定案):
  /// 未接管 = lock_open 灰,点按弹 [onTakeoverRequest] 确认启用;已接管
  /// = lock 金,点按解除(0x90C2 [0])。链路不在时禁点(同原设置浮层
  /// 接管芯片的门);与返回钮同款胶囊内嵌 InkWell(34×30 触达、9 圆角)。
  Widget _takeoverButton(BuildContext context, LivePalette live) {
    final active = controller.takeoverActive;
    return Tooltip(
      message: context.t(active ? 'takeover.active' : 'takeover.title'),
      child: InkWell(
        onTap: !controller.linkUp
            ? null
            : active
                ? controller.releaseTakeover
                : () => onTakeoverRequest(context),
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        child: SizedBox(
          width: 34,
          height: 30,
          child: Icon(
              active ? Icons.lock : Icons.lock_open,
              size: 18,
              color: active ? live.accent : live.muted),
        ),
      ),
    );
  }
}

/// 录制时长标签(m:ss;展示就近取值,事件/交互驱动刷新)。REC 前缀在
/// 胶囊里经 remote.recPrefix 键化(zh/en 同值「REC」:录制指示通用
/// 记号,键化为闸门完整与未来可调);拍摄页唯一直接消费方
/// (2026-10-10 录制钮并入快门后)。
String recDurationLabel(int? seconds) {
  final s = seconds ?? 0;
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// 剩余可录时长标签(帧头 @816 毫秒 → h:mm:ss / m:ss;官方上限
/// 7500000ms ≈ 2 小时,超小时补位避免 125:00 式怪读)。公开给连接页
/// 存储卡脚注复用(2026-10-17 视频档「可录」同源同口径)。
String recRemainingLabel(int ms) {
  final s = (ms / 1000).round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final r = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(r)}' : '$m:${two(r)}';
}
