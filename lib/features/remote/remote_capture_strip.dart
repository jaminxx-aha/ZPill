import 'package:flutter/material.dart';

import '../../core/ptp/operation_codes.dart';
import 'live_design.dart';
import 'remote_controller.dart';
import 'shooting_param_catalog.dart';

/// 读出条 tile 顺序:对齐 OpenZCine photographyCaptureValues
/// (MODE/ISO/SHUTTER/IRIS/DRIVE/FOCUS/WB/METER/PROFILE),其余随后
/// (目录余量按目录序追加 —— AF 区域/主体检测/色调等曾因此不渲染,
/// 2026-10-07 用户反馈「AF 区域/拍摄对象不能改」根因)。
const _stripOrder = <int>[
  PtpDevicePropCode.exposureProgramMode,
  PtpDevicePropCode.exposureIndex,
  PtpDevicePropCode.exposureTime,
  PtpDevicePropCode.fNumber,
  PtpDevicePropCode.stillCaptureMode,
  PtpDevicePropCode.stillFocusMode,
  PtpDevicePropCode.whiteBalance,
  PtpDevicePropCode.wbColorTemp,
  PtpDevicePropCode.exposureMeteringMode,
  PtpDevicePropCode.exposureBiasCompensation,
  PtpDevicePropCode.flashMode,
  PtpDevicePropCode.compressionSetting,
  PtpDevicePropCode.rawCompressionType,
  PtpDevicePropCode.captureAreaCrop,
  PtpDevicePropCode.activePicCtrlItem,
];

/// 读出条/参数栏的参数序:固定序(对齐 OpenZCine
/// photographyCaptureValues:MODE/ISO/SHUTTER/IRIS/DRIVE/FOCUS/WB/
/// METER/PROFILE,见 _stripOrder)+ 目录余量按目录序追加(新参数
/// 默认上栏)。
List<ShootingParam> _orderedParams() => [
      for (final code in _stripOrder)
        if (shootingParamByCode[code] != null) shootingParamByCode[code]!,
      for (final p in kShootingParams)
        if (!_stripOrder.contains(p.code)) p,
    ];

/// 读出条 tile / 读出行 chip 共用的取值状态打包(值经控制器路由:
/// 优化校准槽位真名 0x90CC 优先)。
typedef _ParamState = ({
  String value,
  bool auto,
  bool writable,
  bool locked,
});

_ParamState _paramStateOf(RemoteController controller, ShootingParam p) => (
      value: controller.displayParamValue(
          p.code, controller.paramProps[p.code]?.value),
      auto: controller.paramAutoControlled(p.code),
      writable: controller.propWritable(p.code),
      locked: controller.lockedProps.contains(p.code),
    );

/// 读出条 tile(横屏左参数栏竖列)的取值打包;[dense] 为紧凑态
/// (值 14px + 省略号)。
Widget _captureTileOf(
    BuildContext context,
    RemoteController controller,
    int? activeParam,
    void Function(BuildContext, ShootingParam) onEditParam,
    ShootingParam p,
    {bool dense = false}) {
  final s = _paramStateOf(controller, p);
  return _CaptureTile(
    param: p,
    displayValue: s.value,
    auto: s.auto,
    writable: s.writable,
    active: activeParam == p.code,
    writing: controller.writing,
    locked: s.locked,
    dense: dense,
    onTap: () => onEditParam(context, p),
  );
}

/// 竖屏底部参数读出行(2026-10-08 手机原生相机式排版):无胶囊底的
/// 扁平一行,每参数 = 弱色小标签 + 等宽数值内联平铺,横滚 + 两侧
/// 渐隐(OpenZCine edge fade 同款)。状态随控制器,监听由外层
/// AnimatedBuilder 驱动;[activeParam] 为当前打开面板的参数码(金底
/// pill),[onEditParam] 点按 chip 打开参数编辑面板。
class CaptureReadoutLine extends StatelessWidget {
  const CaptureReadoutLine({
    super.key,
    required this.controller,
    required this.activeParam,
    required this.onEditParam,
  });

  final RemoteController controller;
  final int? activeParam;
  final void Function(BuildContext context, ShootingParam param) onEditParam;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      // 两侧渐隐融入页面底色(读出行不做玻璃胶囊,手机相机语言)
      shaderCallback: (bounds) => const LinearGradient(
        colors: [
          Color(0x00000000),
          Color(0xFF000000),
          Color(0xFF000000),
          Color(0x00000000),
        ],
        stops: [0, 0.03, 0.97, 1],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          children: [
            for (final p in _orderedParams())
              _readoutChipOf(context, controller, activeParam, onEditParam, p),
          ],
        ),
      ),
    );
  }
}

Widget _readoutChipOf(
    BuildContext context,
    RemoteController controller,
    int? activeParam,
    void Function(BuildContext, ShootingParam) onEditParam,
    ShootingParam p) {
  final s = _paramStateOf(controller, p);
  return _ReadoutChip(
    param: p,
    displayValue: s.value,
    auto: s.auto,
    writable: s.writable,
    active: activeParam == p.code,
    writing: controller.writing,
    locked: s.locked,
    onTap: () => onEditParam(context, p),
  );
}

/// 读出行单参数 chip:小标签(10pt,faint;面板打开时金色)+ 等宽数值
/// (13pt)内联一行;自动变量值加「(自动)」后缀置灰。不可调(总闸关断/
/// 模式门锁定/相机只读)时整体降透明度且不可点。
class _ReadoutChip extends StatelessWidget {
  const _ReadoutChip({
    required this.param,
    required this.displayValue,
    required this.auto,
    required this.writable,
    required this.active,
    required this.writing,
    required this.locked,
    required this.onTap,
  });

  final ShootingParam param;
  final String displayValue;
  final bool auto;
  final bool writable;
  final bool active;
  final bool writing;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return InkWell(
      onTap: writable && !writing ? onTap : null,
      customBorder:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      child: Opacity(
        opacity: writable ? 1 : 0.38,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? live.accentDim : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: active
                ? Border.all(color: live.accent.withValues(alpha: 0.5))
                : null,
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  param.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? live.accent.withValues(alpha: 0.85)
                        : live.faint,
                  ),
                ),
                if (locked) ...[
                  const SizedBox(width: 2),
                  Icon(Icons.lock, size: 9, color: live.accent),
                ],
                const SizedBox(width: 5),
                Text(
                  '$displayValue${auto ? '(自动)' : ''}',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: auto ? live.muted : live.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 横屏左参数栏:读出条的竖向滚动版(dense tile:值 14px + 省略号),
/// 上下边缘渐隐同横条(改轴向)。
class ParamRail extends StatelessWidget {
  const ParamRail({
    super.key,
    required this.controller,
    required this.activeParam,
    required this.onEditParam,
  });

  final RemoteController controller;
  final int? activeParam;
  final void Function(BuildContext context, ShootingParam param) onEditParam;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Container(
      width: kParamRailWidth,
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: live.hairline),
      ),
      child: ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00000000),
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x00000000),
          ],
          stops: [0, 0.05, 0.95, 1],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemExtent: 52,
          children: [
            for (final p in _orderedParams())
              _captureTileOf(context, controller, activeParam, onEditParam, p,
                  dense: true),
          ],
        ),
      ),
    );
  }
}

/// 拍摄读出条的单个 tile(OpenZCine CaptureSettingButton 同款):
/// 小标签(9pt,faint;面板打开时金色)+ 大号等宽数字值(自动变量加
/// 「(自动)」后缀并置灰)。不可调(总闸关断/模式门锁定/相机只读)时
/// 整体降透明度且不可点。
class _CaptureTile extends StatelessWidget {
  const _CaptureTile({
    required this.param,
    required this.displayValue,
    required this.auto,
    required this.writable,
    required this.active,
    required this.writing,
    required this.locked,
    required this.onTap,
    this.dense = false,
  });

  final ShootingParam param;

  /// 值文本(经控制器路由:优化校准槽位真名 0x90CC 优先)。
  final String displayValue;
  final bool auto;
  final bool writable;
  final bool active;
  final bool writing;
  final bool locked;
  final VoidCallback onTap;

  /// 横屏左参数栏竖列的紧凑态:值 14px + 省略号(栏宽 ~116)。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final value = displayValue;
    return InkWell(
      onTap: writable && !writing ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Opacity(
        opacity: writable ? 1 : 0.38,
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: dense ? 8 : 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? live.accentDim : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: active
                ? Border.all(
                    color: live.accent.withValues(alpha: 0.5))
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    param.label,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? live.accent.withValues(alpha: 0.85)
                          : live.faint,
                    ),
                  ),
                  if (locked) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.lock, size: 8, color: live.accent),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '$value${auto ? '(自动)' : ''}',
                maxLines: 1,
                overflow:
                    dense ? TextOverflow.ellipsis : TextOverflow.clip,
                style: TextStyle(
                  fontSize: dense ? 14 : 15,
                  fontWeight: FontWeight.w500,
                  color: auto ? live.muted : live.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
