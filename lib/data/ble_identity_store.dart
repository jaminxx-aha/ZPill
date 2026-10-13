/// BLE 配对身份持久化(0x2000 四步握手产物):重连时按 deviceId 扫
/// 广播、以已存 device/nonce 复用握手 —— 相机据此识别旧会话,免重走
/// 菜单配对。独立文件不进 AppSettings(设备资产非用户偏好)。
library;

import 'dart:convert';
import 'dart:io';

/// 已配对相机身份(与 BleCameraSession.identity 同构的落盘形态)。
final class BlePairedIdentity {
  const BlePairedIdentity({
    required this.peripheralUuid,
    required this.deviceId,
    required this.nonce,
    required this.serial,
    required this.controllerName,
    required this.pairedAt,
  });

  /// 系统 BLE 设备标识(iOS peripheral.identifier / Android MAC)。
  final String peripheralUuid;
  final int deviceId;
  final int nonce;

  /// 相机 BLE 侧序列号(stage4 帧,独立于 USB 序列;握手期未到时空)。
  final String serial;
  final String controllerName;
  final DateTime pairedAt;

  Map<String, Object?> toJson() => {
        'peripheralUuid': peripheralUuid,
        'deviceId': deviceId,
        'nonce': nonce,
        'serial': serial,
        'controllerName': controllerName,
        'pairedAt': pairedAt.toIso8601String(),
      };

  static BlePairedIdentity? fromJson(Map<String, Object?> json) {
    final uuid = json['peripheralUuid'] as String?;
    final deviceId = json['deviceId'] as int?;
    final nonce = json['nonce'] as int?;
    if (uuid == null || deviceId == null || nonce == null) return null;
    final pairedAtRaw = json['pairedAt'] as String?;
    return BlePairedIdentity(
      peripheralUuid: uuid,
      deviceId: deviceId,
      nonce: nonce,
      serial: json['serial'] as String? ?? '',
      controllerName: json['controllerName'] as String? ?? 'NikonPill',
      pairedAt:
          pairedAtRaw == null ? DateTime.now() : DateTime.parse(pairedAtRaw),
    );
  }
}

final class BleIdentityStore {
  BleIdentityStore({required Future<String> Function() dataDir})
      : _dataDir = dataDir;

  final Future<String> Function() _dataDir;

  /// 取(无档返回 null);损坏文件按未配对处理。
  Future<BlePairedIdentity?> load() async {
    final file = File('${await _dataDir()}/ble_identity.json');
    if (!await file.exists()) return null;
    try {
      final j = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return BlePairedIdentity.fromJson(j);
    } on FormatException {
      return null;
    }
  }

  /// 配对成功落档(覆盖旧身份 —— 单相机场景一个槽位足够)。
  Future<void> save(BlePairedIdentity identity) async {
    final file = File('${await _dataDir()}/ble_identity.json');
    await file.create(recursive: true);
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(identity.toJson()));
  }

  /// 清档(设置页「解除配对」;下次配对走全新握手)。
  Future<void> clear() async {
    final file = File('${await _dataDir()}/ble_identity.json');
    if (await file.exists()) {
      try {
        await file.delete();
      } on FileSystemException {
        // 删失败无妨:下次 save 覆盖
      }
    }
  }
}
