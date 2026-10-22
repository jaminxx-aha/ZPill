/**
 * ZPill 原生日志上报(ohos 平台,native 侧)—— native → Dart 反向通道。
 *
 * 对应 Dart 契约 lib/platform/log_bridge.dart(MethodChannel `zpill/log`):
 * native → Dart 调 'onNativeLog',参数 {level: "d"|"i"|"w"|"e", tag, line},
 * 由 Dart 合流进 AppLog 的 native 域。三端 native 在关键路径(USB bulk
 * 失败 / BLE 状态沿)显式上报、不做 hilog 抓流;iOS/Android 各有对等件
 * (NativeLog.swift / NativeLog.kt,同名同参)。
 *
 * 契约要点(与 Dart 侧注释一致):
 * - fire-and-forget:invokeMethod 全量 try/catch 吞错(Dart handler 未
 *   装配 / 引擎已 detach 都不反噬调用方);不带 callback,回复天然丢弃。
 * - 恒主线程 invoke:ohos 通道回调与 BLE/USB 回调默认都在主线程,直接
 *   调用即满足 BinaryMessenger 的单线程纪律(引擎在主线程创建)。
 * - install 前的上报静默丢弃(channel 为 null 直接返回);EntryAbility
 *   在 configureFlutterEngine 最先装配,早于一切插桩点。
 */
import { BinaryMessenger, MethodChannel } from '@ohos/flutter_ohos';

const LOG_CHANNEL = 'zpill/log';

/** 无实例命名空间:插桩点一行调用(e/w/i),别处零成本。 */
export class NativeLog {
  /** 反向通道(EntryAbility 在 configureFlutterEngine 里 install,常驻)。 */
  private static channel: MethodChannel | null = null;

  /**
   * 装配点。无条件覆写:引擎重建即换 messenger,旧通道指向死引擎只会
   * 白抛异常(Android 侧 volumeChannel 同款重装,不做幂等守卫)。
   */
  static install(messenger: BinaryMessenger): void {
    NativeLog.channel = new MethodChannel(messenger, LOG_CHANNEL);
  }

  static e(tag: string, line: string): void {
    NativeLog.send('e', tag, line);
  }

  static w(tag: string, line: string): void {
    NativeLog.send('w', tag, line);
  }

  static i(tag: string, line: string): void {
    NativeLog.send('i', tag, line);
  }

  private static send(level: string, tag: string, line: string): void {
    const ch = NativeLog.channel;
    if (ch === null) {
      return;
    }
    try {
      ch.invokeMethod('onNativeLog', {
        'level': level,
        'tag': tag,
        'line': line,
      } as Record<string, Object>);
    } catch (e) {
      // Dart handler 未装配 / 引擎已 detach:fire-and-forget,吞掉
    }
  }
}
