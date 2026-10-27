/// CameraConnection 测试桩:八份逐字拷贝的 `_FakeConnection` 合并
/// (2026-10-22,原散在 connection/remote/browser/shell 各测试)。
/// 可变读数 + 方法计数供断言;状态沿由 [statesCtrl] 驱动(或 [emit])。
library;

import 'dart:async';

import 'package:z_pill/core/camera/camera_connection.dart';
import 'package:z_pill/l10n/message.dart';

final class FakeConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  @override
  CameraLinkState state = CameraLinkState.disconnected;

  /// 连接层动态文案(reconnecting 期恢复循环逐拍更新;failed 终态)。
  @override
  L10nMessage? error;

  @override
  String? deviceName;

  @override
  String? deviceModel;

  @override
  bool isWireless = false;

  @override
  String? pairingCode;

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  int confirmCalls = 0;
  int cancelCalls = 0;
  int disconnectCalls = 0;
  String? connectIp;
  String? connectInstanceName;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {
    connectIp = ip;
    connectInstanceName = instanceName;
  }

  @override
  Future<void> confirmPairing() async => confirmCalls++;

  @override
  Future<void> cancelPairing() async => cancelCalls++;

  @override
  Future<void> disconnect() async => disconnectCalls++;

  /// 推一个连接状态沿(等效 statesCtrl.add,语义化入口)。
  void emit(CameraLinkState s) => statesCtrl.add(s);
}
