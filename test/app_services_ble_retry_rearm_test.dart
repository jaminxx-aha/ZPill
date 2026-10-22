import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/app_services.dart';
import 'package:z_pill/core/ble/ble_camera_session.dart';

/// 重连循环重臂谓词(2026-10-17 全自动重连定案):无命中不即死 ——
/// reconnecting(连上又掉)或 idle+有身份(冷启扫空/深睡闸门等唤醒)
/// 都续跑;命中(ok)/驱动停/身份没了才收。
void main() {
  test('reconnecting + 无命中 → 重臂(掉线循环不死)', () {
    expect(
        bleRetryRearm(
            ok: false,
            running: true,
            state: BleSessionState.reconnecting,
            hasIdentity: true),
        isTrue);
  });

  test('idle + 有身份 → 重臂(冷启扫空/闸门等唤醒都续轮询)', () {
    expect(
        bleRetryRearm(
            ok: false,
            running: true,
            state: BleSessionState.idle,
            hasIdentity: true),
        isTrue);
  });

  test('idle + 无身份 → 收(解除配对沿)', () {
    expect(
        bleRetryRearm(
            ok: false,
            running: true,
            state: BleSessionState.idle,
            hasIdentity: false),
        isFalse);
  });

  test('命中(ok)→ 收', () {
    expect(
        bleRetryRearm(
            ok: true,
            running: true,
            state: BleSessionState.ready,
            hasIdentity: true),
        isFalse);
  });

  test('驱动停(running=false)→ 收(挂起/开关沿让位)', () {
    expect(
        bleRetryRearm(
            ok: false,
            running: false,
            state: BleSessionState.reconnecting,
            hasIdentity: true),
        isFalse);
  });
}
