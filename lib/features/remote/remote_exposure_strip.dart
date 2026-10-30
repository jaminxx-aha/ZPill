import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/ptp/operation_codes.dart';
import '../../l10n/l10n.dart';
import 'live_design.dart';
import 'remote_capture_strip.dart';
import 'remote_controller.dart';
import 'shooting_param_catalog.dart';

/// 取景页底部曝光条(第 2 轮定稿,第 4 轮落地):六格 —— 模式 / 快门 /
/// 光圈 / ISO / EV / 白平衡。透明玻璃压画面,选中格只用顶部琥珀细线,
/// 不用实底;点格直接打开对应参数底单(接管门在底单里,与设置面板
/// 同一路)。数值全部来自 [RemoteController] 的 displayParamValue,
/// 不在这里拼协议值。
class CaptureExposureStrip extends StatelessWidget {
  const CaptureExposureStrip({
    super.key,
    required this.controller,
    required this.height,
    required this.onTapParam,
    this.activeCode,
  });

  final RemoteController controller;
  final double height;
  final void Function(BuildContext context, ShootingParam param) onTapParam;
  final int? activeCode;

  static const _codes = <int>[
    PtpDevicePropCode.exposureProgramMode,
    PtpDevicePropCode.exposureTime,
    PtpDevicePropCode.fNumber,
    PtpDevicePropCode.exposureIndex,
    PtpDevicePropCode.exposureBiasCompensation,
    PtpDevicePropCode.whiteBalance,
  ];

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final params = <ShootingParam>[
      for (final code in _codes)
        if (shootingParamByCode[code] != null) shootingParamByCode[code]!,
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          key: const ValueKey('remote-exposure-strip'),
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: live.surface.withValues(alpha: 0.38),
            border: Border.all(color: live.hairline),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              for (final p in params) Expanded(child: _cell(context, live, p)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, LivePalette live, ShootingParam p) {
    final s = captureParamState(controller, p);
    final active =
        (activeCode ?? PtpDevicePropCode.exposureProgramMode) == p.code;
    return Semantics(
      button: s.writable,
      label: context.t(p.label),
      child: InkWell(
        key: ValueKey('exposure-${p.code}'),
        onTap: s.writable && !controller.writing
            ? () => onTapParam(context, p)
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: active ? live.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(5, 5, 5, 4),
          child: Opacity(
            opacity: s.writable ? 1 : 0.4,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      text: context.t(p.label),
                      style: TextStyle(
                        fontFamily: 'InterBadge',
                        fontFamilyFallback: const ['NotoSansSC'],
                        fontSize: 9.5,
                        height: 1.1,
                        fontWeight: FontWeight.w500,
                        color: live.muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: RichText(
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        text:
                            '${context.tm(s.value)}${s.auto ? context.t('common.autoSuffix') : ''}',
                        style: TextStyle(
                          fontFamily: 'InterBadge',
                          fontFamilyFallback: const ['NotoSansSC'],
                          fontSize: 14,
                          height: 1.15,
                          fontWeight: FontWeight.w600,
                          color: s.auto ? live.muted : live.text,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
