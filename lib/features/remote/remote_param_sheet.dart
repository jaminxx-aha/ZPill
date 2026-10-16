import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ptp/operation_codes.dart';
import '../../l10n/l10n.dart';
import '../common/widgets/confirm_dialog.dart';
import 'live_design.dart';
import 'remote_controller.dart';
import 'shooting_param_catalog.dart';

/// 拍摄参数编辑面板:取值域 = 相机 PropDesc 枚举(权威)或目录
/// pickValues 直供(快门:标准档打包表等厂商码场景);范围域 → 滑条;
/// 域未知 → 只读提示。选中即写(0x1016)并按读码路由回读刷新,不额外
/// 确认 —— 相机侧可随时再调。**列表打开即定位到当前值**(不从列表头
/// 开始 —— 长列表如快门 54 档)。
///
/// **双层跳合一**:拨盘拥有参数(快门/模式/ISO/光圈)且未接管时,面板
/// 先出接管区(原「启用 APP 接管控制?」确认对话框的两行文案 + 启用
/// 钮搬进面板头),点按启用后 AnimatedSwitcher 换出值列表 —— 不再
/// 对话框跳一层。信息胶囊行尾「APP 接管」钮仍走 [confirmTakeover]
/// 对话框(2026-10-17 自设置浮层芯片迁来)。
Future<void> showParamEditSheet(
    BuildContext context, RemoteController controller, ShootingParam p) async {
  final state = controller.paramProps[p.code];
  final desc = state?.desc;
  // 取值域:相机 PropDesc 枚举优先(权威),拒答/无 FORM 时目录
  // pickValues 直供(快门/对焦模式/图像区域等厂商码场景)。
  final enums = desc?.enumValues?.whereType<int>().toList(growable: false) ??
      p.pickValues;
  final rangeMin = desc?.rangeMin as int?;
  final rangeMax = desc?.rangeMax as int?;
  final rangeStep = desc?.rangeStep as int? ?? 1;
  // 定位:当前值在列表中的序号(ISO 面板有置顶的「自动 ISO」条目,+1)
  final hasIsoAutoTile =
      p.code == PtpDevicePropCode.exposureIndex && controller.isoAuto != null;
  final currentIndex =
      (enums?.indexOf(state?.value ?? -1) ?? -1) + (hasIsoAutoTile ? 1 : 0);
  final listCtrl = ScrollController();
  var centered = false;
  var enabling = false;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: LiveDesign.of(context).surface,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final live = LiveDesign.of(context);
          final current = controller.paramProps[p.code]?.value;
          final writing = controller.writing; // 写中防连点
          final needTakeover = p.dialOwned && !controller.takeoverActive;
          // 值列表真正上屏才定位(接管区先出时列表未挂载,提前定位会
          // 错过 —— centered 是一次性开关)。
          if (!centered &&
              !needTakeover &&
              enums != null &&
              enums.isNotEmpty &&
              currentIndex > 2) {
            // 首帧布局后跳到当前值(顶上留两行上下文)
            centered = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (listCtrl.hasClients) {
                listCtrl.jumpTo((currentIndex - 2) * kParamSheetItemExtent);
              }
            });
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                // 目录 label(shooting_param_catalog 产出)原文即 t() 键,
                // 显示点包 t()。
                child: Text(context.t(p.label),
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: live.muted)),
              ),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: needTakeover
                      ? TakeoverSection(
                          key: const ValueKey('takeover'),
                          busy: enabling,
                          onEnable: () {
                            enabling = true;
                            unawaited(controller
                                .enableTakeover()
                                .then((_) => enabling = false));
                          },
                        )
                      : _valueSection(
                          key: const ValueKey('values'),
                          sheetContext: sheetContext,
                          live: live,
                          controller: controller,
                          p: p,
                          enums: enums,
                          rangeMin: rangeMin,
                          rangeMax: rangeMax,
                          rangeStep: rangeStep,
                          current: current,
                          writing: writing,
                          hasIsoAutoTile: hasIsoAutoTile,
                          listCtrl: listCtrl,
                        ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
  // 面板关闭后释放列表控制器(等一帧,避开退出动画中的惯性访问)
  WidgetsBinding.instance.addPostFrameCallback((_) => listCtrl.dispose());
}

/// 面板的值列表/滑条/域未知三分支(接管完成后换入)。
Widget _valueSection({
  required Key key,
  required BuildContext sheetContext,
  required LivePalette live,
  required RemoteController controller,
  required ShootingParam p,
  required List<int>? enums,
  required int? rangeMin,
  required int? rangeMax,
  required int rangeStep,
  required Object? current,
  required bool writing,
  required bool hasIsoAutoTile,
  required ScrollController listCtrl,
}) {
  if (enums != null && enums.isNotEmpty) {
    // AF 区域(0xD05D)的宽C1/C2 是横带/竖条饱和区:触屏移框饱和轴
    // 不动属相机行为 —— 面板常驻一行说明(切换沿另有 notice)。
    final afAreaHint = p.code == PtpDevicePropCode.stillFocusMeteringMode
        ? sheetContext.t('param.wideAreaHint')
        : null;
    final list = ListView(
      key: key,
      shrinkWrap: true,
      controller: listCtrl,
      itemExtent: kParamSheetItemExtent,
      children: [
        // ISO 面板置顶「自动 ISO」开关(0xD054;与手动值互不干扰 ——
        // 开关只在这里显式控制)。
        if (hasIsoAutoTile)
          ListTile(
            title: Text(sheetContext.t('param.autoIso'),
                style: TextStyle(color: live.text)),
            trailing: controller.isoAuto == true
                ? Icon(Icons.check, color: live.accent)
                : null,
            onTap: writing
                ? null
                : () {
                    Navigator.of(sheetContext).pop();
                    controller.setIsoAuto(!(controller.isoAuto!));
                  },
          ),
        for (final v in enums)
          ListTile(
            // 槽位真名(0x90CC)优先:优化校准自定义/云组
            // 静态表只有「自定义 N」「云 N」占位。
            // 值文案(displayParamValue,目录/控制器产出)原文即 t() 键,
            // 显示点包 t()。
            title: Text(sheetContext.t(controller.displayParamValue(p.code, v)),
                style: TextStyle(color: live.text)),
            trailing:
                v == current ? Icon(Icons.check, color: live.accent) : null,
            onTap: writing
                ? null
                : () {
                    Navigator.of(sheetContext).pop();
                    controller.setParam(p.code, v);
                  },
          ),
      ],
    );
    if (afAreaHint == null) return list;
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Text(afAreaHint,
              style: TextStyle(fontSize: 11, color: live.muted)),
        ),
        Flexible(child: list),
      ],
    );
  }
  if (rangeMin != null &&
      rangeMax != null &&
      rangeMax > rangeMin &&
      current is int) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        children: [
          Text(sheetContext.t(controller.displayParamValue(p.code, current)),
              style: TextStyle(
                  fontSize: 30, fontWeight: FontWeight.w500, color: live.text)),
          Slider(
            value: (current.clamp(rangeMin, rangeMax)).toDouble(),
            min: rangeMin.toDouble(),
            max: rangeMax.toDouble(),
            divisions: ((rangeMax - rangeMin) ~/ rangeStep).clamp(1, 1 << 20),
            label:
                sheetContext.t(controller.displayParamValue(p.code, current)),
            activeColor: live.accent,
            onChanged: writing ? null : (_) {},
            onChangeEnd: (v) => controller.setParam(p.code, v.round()),
          ),
        ],
      ),
    );
  }
  return Padding(
    key: key,
    padding: const EdgeInsets.all(24),
    child: Text(sheetContext.t('param.rangeUnknown'),
        style: TextStyle(color: live.muted)),
  );
}

/// 面板头的接管区(原确认对话框文案原样搬入):启用后随控制器通知
/// 换出值列表。按钮手绘金底,颜色随应用主题(拍摄页 chrome 已随
/// 主题,2026-10-08)。模式条点按的接管门(未接管时,remote_mode_sheet)
/// 同用本件 —— 同一文案一处维护。
class TakeoverSection extends StatelessWidget {
  const TakeoverSection(
      {super.key, required this.busy, required this.onEnable});

  final bool busy;

  /// 启用中防连点(0x90C2 往返期间钮置灰)。
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('takeover.confirmTitle'),
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: live.text)),
          const SizedBox(height: 10),
          Text(
            context.t(
              'takeover.confirmBody',
            ),
            style: TextStyle(fontSize: 13, height: 1.5, color: live.muted),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: Material(
              color: busy ? live.accentDim : live.accent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: busy ? null : onEnable,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: busy
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: live.onAccent),
                          )
                        : Text(context.t('takeover.enable'),
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: live.onAccent)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「启用 APP 接管控制」确认(影控台同款语义):受机身物理拨盘控制
/// 的参数需先接管(0x90C2 remote 模式)才能遥控调整;接管期间机身
/// 拨盘可能被锁定、机身屏幕可能熄灭。返回是否已接管(含已激活直通)。
Future<bool> confirmTakeover(
    BuildContext context, RemoteController controller) async {
  if (controller.takeoverActive) return true;
  final confirmed = await showConfirmDialog(
    context,
    title: context.t('takeover.confirmTitle'),
    content: context.t(
      'takeover.confirmBody',
    ),
    confirmLabel: context.t('takeover.enable'),
  );
  if (!confirmed) return false;
  return controller.enableTakeover();
}
