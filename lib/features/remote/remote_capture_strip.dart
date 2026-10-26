import 'package:flutter/material.dart';

import '../../core/ptp/operation_codes.dart';
import '../../l10n/l10n.dart';
import '../../l10n/message.dart';
import 'live_design.dart';
import 'remote_controller.dart';
import 'shooting_param_catalog.dart';

/// 参数序 tile 顺序:对齐 OpenZCine photographyCaptureValues
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

/// 设置面板参数区的参数序:固定序(对齐 OpenZCine
/// photographyCaptureValues:MODE/ISO/SHUTTER/IRIS/DRIVE/FOCUS/WB/
/// METER/PROFILE,见 _stripOrder)+ 目录余量按目录序追加(新参数
/// 默认上面板)+ **视频档追加视频参数族 [kVideoShootingParams]**
/// ([videoMode] = 控制器 cameraMode == video;照片档不出现,零噪声)
/// **并收起 [ShootingParam.photoOnly] 照片曝光块**(视频孪生码接管
/// 曝光,照片码在休眠静照管线空转;2026-10-26 USB 矩阵,用户真机
/// 「调了 ISO 没效果」根因)。
/// 2026-10-12 竖屏读出行与横屏左参数栏先后删除,设置面板成为唯一
/// 消费方。
List<ShootingParam> orderedCaptureParams({bool videoMode = false}) => [
      for (final code in _stripOrder)
        if (shootingParamByCode[code] != null &&
            !(videoMode && shootingParamByCode[code]!.photoOnly))
          shootingParamByCode[code]!,
      for (final p in kShootingParams)
        if (!_stripOrder.contains(p.code) && !(videoMode && p.photoOnly)) p,
      if (videoMode) ...kVideoShootingParams,
    ];

/// 设置面板 tile 共用的取值状态打包(值经
/// 控制器路由:优化校准槽位真名 0x90CC 优先;值为键+参记录,渲染点
/// tm() 落地)。
typedef CaptureParamState = ({
  L10nMessage value,
  bool auto,
  bool writable,
  bool locked,
});

CaptureParamState captureParamState(RemoteController controller, ShootingParam p) =>
    (
      value: controller.displayParamValue(
          p.code, controller.paramProps[p.code]?.value),
      auto: controller.paramAutoControlled(p.code),
      writable: controller.propWritable(p.code),
      locked: controller.lockedProps.contains(p.code),
    );

/// 读出条 tile(设置面板参数区)的取值打包与落 tile。
Widget captureParamTileOf(
    BuildContext context,
    RemoteController controller,
    int? activeParam,
    void Function(BuildContext, ShootingParam) onEditParam,
    ShootingParam p) {
  final s = captureParamState(controller, p);
  return CaptureParamTile(
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

/// 拍摄读出条的单个 tile(OpenZCine CaptureSettingButton 同款;2026-10-10
/// 随设置面板复用公开;2026-10-17 面板参数区改等宽格子,值文本 FittedBox
/// 缩放 —— 变宽 Wrap 时代 tile 无宽度上限,优化校准槽位真名等长值超出
/// 面板宽直接被裁,格子定宽后缩放适配不丢字)。小标签(10pt,faint;
/// 面板打开时金色)+ 等宽数字值(自动变量加「(自动)」后缀并置灰)。
/// 不可调(总闸关断/模式门锁定/相机只读)时整体降透明度且不可点。
class CaptureParamTile extends StatelessWidget {
  const CaptureParamTile({
    super.key,
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

  /// 值文本(经控制器路由:优化校准槽位真名 0x90CC 优先;键+参记录,
  /// 渲染点 tm() 落地)。
  final L10nMessage displayValue;
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
      borderRadius: BorderRadius.circular(10),
      child: Opacity(
        opacity: writable ? 1 : 0.38,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
                  // 目录 label(shooting_param_catalog 产出)原文即
                  // t() 键,显示点包 t()。Flexible 截断:等宽格子定宽后,
                  // 长标签(H.265 色调/视频白平衡)不再溢出 —— 全名在
                  // 编辑底单标题可见。
                  Flexible(
                    child: Text(
                      context.t(param.label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: active
                            ? live.accent.withValues(alpha: 0.85)
                            : live.faint,
                      ),
                    ),
                  ),
                  if (locked) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.lock, size: 8, color: live.accent),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              // 值文本(displayValue 经控制器路由 displayParamValue 产出)
              // 为键+参记录,显示点 tm() 一次落地;「(自动)」后缀同查
              // 目录。FittedBox 只缩不放:常规值(800/f/2.0/AF-C)原字号,
              // 长值(槽位真名/1/160s(自动))整串缩到格宽内。
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${context.tm(displayValue)}${auto ? context.t('common.autoSuffix') : ''}',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: auto ? live.muted : live.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
