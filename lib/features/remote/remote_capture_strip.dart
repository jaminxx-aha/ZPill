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

/// 读出条 tile(竖屏底部横滚 / 横屏左参数栏竖列共用)的取值打包;
/// [dense] 为左栏紧凑态(值 14px + 省略号)。
Widget _captureTileOf(
    BuildContext context,
    RemoteController controller,
    int? activeParam,
    void Function(BuildContext, ShootingParam) onEditParam,
    ShootingParam p,
    {bool dense = false}) {
  return _CaptureTile(
    param: p,
    displayValue:
        controller.displayParamValue(p.code, controller.paramProps[p.code]?.value),
    auto: controller.paramAutoControlled(p.code),
    writable: controller.propWritable(p.code),
    active: activeParam == p.code,
    writing: controller.writing,
    locked: controller.lockedProps.contains(p.code),
    dense: dense,
    onTap: () => onEditParam(context, p),
  );
}

/// 竖屏拍摄读出条:全部参数 tile 横滚,两侧边缘渐隐(OpenZCine
/// edge fade 同款)。状态随控制器,监听由外层 AnimatedBuilder 驱动;
/// [activeParam] 为当前打开面板的参数码(tile 金框),[onEditParam]
/// 点按 tile 打开参数编辑面板。
class CaptureStrip extends StatelessWidget {
  const CaptureStrip({
    super.key,
    required this.controller,
    required this.activeParam,
    required this.onEditParam,
    this.margin,
  });

  final RemoteController controller;
  final int? activeParam;
  final void Function(BuildContext context, ShootingParam param) onEditParam;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: live.hairline),
      ),
      child: Stack(
        children: [
          // 边缘渐隐(OpenZCine edge fade 同款):两侧各 ~12px 融入玻璃
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [
                Color(0x00000000),
                Color(0xFF000000),
                Color(0xFF000000),
                Color(0x00000000),
              ],
              stops: [0, 0.035, 0.965, 1],
            ).createShader(bounds),
            blendMode: BlendMode.dstIn,
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final p in _orderedParams())
                    _captureTileOf(context, controller, activeParam,
                        onEditParam, p),
                ],
              ),
            ),
          ),
        ],
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
