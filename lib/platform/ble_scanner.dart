/// BLE 宿主契约:扫描 / GATT 连接 / 读写 / 订阅(三端同一 channel 契约)。
///
/// 对应原生:iOS CoreBluetooth(ios/Runner/BlePlugin.swift);Android
/// BluetoothLeScanner、ohos @ohos.bluetooth.ble 待补(缺失时调用抛
/// MissingPluginException,上层按「平台不支持」降级)。
///
/// 铁律:
/// - 扫描必须设超时(相机 BLE 广播仅在配对模式持续约 60-120s)
/// - 按名称匹配,**不按 UUID 过滤**(扫描不传服务 UUID 白名单)
/// - 连接走系统 GATT 免 PIN 形态,不主动建 Classic bond
/// - 协议方言(配对握手/0x2005/0x2007 载荷)全在 lib/core/ble/,本层零知识
///
/// 事件流 `nikonpill/ble/events`(载荷见各类):
/// - BleStateChanged:蓝牙开关态(poweredOn/poweredOff/…)
/// - BleDeviceFound:扫描发现(mfg = 厂商数据原始字节,重连匹配 0x0399+4B deviceId 用)
/// - BleConnected:连接就绪(服务发现完成),带全特征表与无响应写 MTU
/// - BleDisconnected:断连(含主动与意外)
/// - BleNotified:indicate/notify 数据(以 uuid 区分 0x2000/0x2008 等)
/// - BleError:GATT 错误(相机拒写/特征缺失等)
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 一次扫描发现的 BLE 设备。
final class BleDevice {
  const BleDevice({
    required this.name,
    required this.uuid,
    required this.rssi,
    this.mfgData,
  });

  /// 广播名(Zf 配对态如 `Z f_8014411`;可能为空串)。
  final String name;

  /// 系统侧设备标识(iOS peripheral.identifier / Android MAC)。
  final String uuid;

  final int rssi;

  /// 厂商数据原始字节(Nikon 0x0399:首两字节 = LE 公司 ID,其后
  /// 4B = deviceId LE,重连匹配用)。
  final Uint8List? mfgData;

  static BleDevice fromMap(Map<Object?, Object?> map) => BleDevice(
        name: map['name'] as String? ?? '',
        uuid: map['uuid'] as String? ?? '',
        rssi: map['rssi'] as int? ?? 0,
        mfgData: map['mfg'] as Uint8List?,
      );
}

/// BLE 事件流元素(sealed,native 载荷 Map → 类型化事件)。
sealed class BleEvent {
  const BleEvent();
}

final class BleStateChanged extends BleEvent {
  const BleStateChanged(this.state);
  final String state;
}

final class BleDeviceFound extends BleEvent {
  const BleDeviceFound(this.device);
  final BleDevice device;
}

final class BleConnected extends BleEvent {
  const BleConnected({
    required this.uuid,
    required this.characteristics,
    required this.writeWithoutResponseMtu,
  });

  final String uuid;

  /// 全特征表:uuid → 属性串(read/write/notify/indicate 以 | 连接)。
  final Map<String, String> characteristics;

  final int writeWithoutResponseMtu;
}

final class BlePreConnected extends BleEvent {
  const BlePreConnected(this.uuid);
  final String uuid;
}

final class BleDisconnected extends BleEvent {
  const BleDisconnected(this.uuid);
  final String uuid;
}

final class BleNotified extends BleEvent {
  const BleNotified({required this.uuid, required this.data});
  final String uuid;
  final Uint8List data;
}

final class BleError extends BleEvent {
  const BleError({required this.code, required this.message, this.uuid});
  final String code;
  final String? uuid;
  final String message;
}

abstract interface class BleHost {
  /// 事件流(广播语义;未触蓝牙前静默无流)。
  Stream<BleEvent> get events;

  /// 蓝牙已开(poweredOn)。首次调用会触发系统蓝牙权限弹窗。
  Future<bool> isAvailable();

  /// 配对扫描(相机进配对菜单后调;默认 10s,TODO.md §二)。
  Future<List<BleDevice>> scan({Duration timeout});

  /// 停止扫描并返回已收集设备。
  Future<void> stopScan();

  /// 重连扫描:只收广播厂商数据 = 0x0399 + deviceId(小端 4B)的设备。
  Future<List<BleDevice>> scanForDeviceId(int deviceId, {Duration timeout});

  /// 连接已配对/已发现设备(peripheralUuid = [BleDevice.uuid])。
  /// 就绪以 BleConnected 事件为准(服务发现完成后发出)。
  Future<void> connectPaired(String peripheralUuid);

  /// 订阅 indicate/notify(indicate 同走此路)。
  Future<void> setNotify(String characteristicUuid);

  /// 读特征值。
  Future<Uint8List?> read(String characteristicUuid);

  /// 写特征值(0x2000/0x2002/0x2005/0x2006/0x2007);[withoutResponse]
  /// 仅在高频心跳场景考虑,默认带响应(相机拒写以错误返回)。
  Future<void> write(String characteristicUuid, Uint8List data,
      {bool withoutResponse = false});

  Future<void> disconnect();
}

/// 经 `nikonpill/ble` + `nikonpill/ble/events`。
final class MethodChannelBleHost implements BleHost {
  static const MethodChannel _methods = MethodChannel('nikonpill/ble');
  static const EventChannel _events = EventChannel('nikonpill/ble/events');

  Stream<BleEvent>? _stream;

  @override
  Stream<BleEvent> get events =>
      _stream ??= _events.receiveBroadcastStream().expand(_parseEvent);

  @override
  Future<bool> isAvailable() async => await _methods.invokeMethod<bool>(
          'isAvailable') ??
      false;

  @override
  Future<List<BleDevice>> scan({Duration timeout = const Duration(seconds: 10)}) =>
      _invokeScan('scan', null, timeout);

  @override
  Future<void> stopScan() => _methods.invokeMethod<void>('stopScan');

  @override
  Future<List<BleDevice>> scanForDeviceId(int deviceId,
          {Duration timeout = const Duration(seconds: 10)}) =>
      _invokeScan('scanForDeviceId', deviceId, timeout);

  @override
  Future<void> connectPaired(String peripheralUuid) =>
      _methods.invokeMethod<void>('connectPaired', peripheralUuid);

  @override
  Future<void> setNotify(String characteristicUuid) =>
      _methods.invokeMethod<void>('setNotify', characteristicUuid);

  @override
  Future<Uint8List?> read(String characteristicUuid) =>
      _methods.invokeMethod<Uint8List?>('read', characteristicUuid);

  @override
  Future<void> write(String characteristicUuid, Uint8List data,
          {bool withoutResponse = false}) =>
      _methods.invokeMethod<void>('write', <String, Object?>{
        'uuid': characteristicUuid,
        'data': data,
        'withoutResponse': withoutResponse,
      });

  @override
  Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');

  Future<List<BleDevice>> _invokeScan(
      String method, int? deviceId, Duration timeout) async {
    final raw = await _methods.invokeMethod<List<Object?>?>(method, <String,
        Object?>{
      if (deviceId != null) 'deviceId': deviceId,
      'seconds': timeout.inSeconds,
    });
    return (raw ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(BleDevice.fromMap)
        .toList(growable: false);
  }

  static Iterable<BleEvent> _parseEvent(Object? raw) sync* {
    if (raw is! Map) return;
    final map = Map<Object?, Object?>.from(raw);
    switch (map['type']) {
      case 'state':
        yield BleStateChanged(map['state'] as String? ?? 'unknown');
      case 'discovered':
        yield BleDeviceFound(BleDevice.fromMap(map));
      case 'connected':
        final chars = <String, String>{};
        final rawChars = map['characteristics'];
        if (rawChars is Map) {
          rawChars.forEach((k, v) => chars['$k'] = '$v');
        }
        yield BleConnected(
          uuid: map['uuid'] as String? ?? '',
          characteristics: chars,
          writeWithoutResponseMtu: map['mtu'] as int? ?? 20,
        );
      case 'preconnected':
        yield BlePreConnected(map['uuid'] as String? ?? '');
      case 'disconnected':
        yield BleDisconnected(map['uuid'] as String? ?? '');
      case 'notify':
        yield BleNotified(
          uuid: map['uuid'] as String? ?? '',
          data: (map['data'] as Uint8List?) ?? Uint8List(0),
        );
      case 'error':
        yield BleError(
          code: map['code'] as String? ?? 'unknown',
          message: map['message'] as String? ?? '',
          uuid: map['uuid'] as String?,
        );
    }
  }
}
