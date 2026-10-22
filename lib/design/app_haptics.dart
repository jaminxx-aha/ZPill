import 'package:flutter/services.dart';

/// 统一触感入口(design token 层):全工程触感只从这里的语义化方法出,
/// 调用面只见语义 —— 将来接 native 触感引擎只改本文件这一处替换点。
/// 各方法直接转发 [HapticFeedback]:widget 测试里方法通道默认 mock,
/// 调用即安全 no-op,无需测试环境判断。
abstract final class AppHaptics {
  /// 快门按下(本地确认沿,不等相机应答):lightImpact —— 拍照高频、连拍按住连续触发,轻震够确认不打扰。
  static Future<void> shutter() => HapticFeedback.lightImpact();

  /// 录像起/停(重状态迁移沿):mediumImpact —— 比单张拍照重一档,起停录须醒目。
  static Future<void> recordToggle() => HapticFeedback.mediumImpact();

  /// 轻量选择(模式条切档/评分逐星):selectionClick —— 系统级选择点按,最轻一档。
  static Future<void> selection() => HapticFeedback.selectionClick();

  /// 操作成功(配对成功/保存到相册/复制到剪贴板):mediumImpact —— 终态确认重于选择,并与 remote_banner 既有复制震感(mediumImpact)统一。
  static Future<void> success() => HapticFeedback.mediumImpact();
}
