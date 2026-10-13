// NikonPill BLE 裸桥(iOS CoreBluetooth,native 侧)。
//
// 对应 Dart 契约 lib/platform/ble_scanner.dart(BleHost):
// MethodChannel `nikonpill/ble` + EventChannel `nikonpill/ble/events`。
// 协议逻辑(配对握手/GEO/TIME 载荷)全在 Dart(lib/core/ble/),
// 本桥只做扫描/连接/GATT 读写订阅的搬运,零 Nikon 方言知识。
//
// 事件载荷(Map):state / discovered / connected(附全特征表与
// 无响应写 MTU)/ disconnected / notify(indicate 同走此路,以 uuid
// 区分 0x2000/0x2008)/ error。
//
// Info.plist 需要 NSBluetoothAlwaysUsageDescription;后台常驻另见
// UIBackgroundModes(bluetooth-central/location)。

import CoreBluetooth
import Flutter
import UIKit

public final class BlePlugin: NSObject, FlutterPlugin, CBCentralManagerDelegate, CBPeripheralDelegate, FlutterStreamHandler {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BlePlugin()
    let channel = FlutterMethodChannel(
      name: "nikonpill/ble", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(
      name: "nikonpill/ble/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  private var sink: FlutterEventSink?
  // 懒建:CBCentralManager 一创建即触发系统蓝牙权限弹窗,别在启动时抢。
  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?

  private struct ScanHit {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    let mfg: Data
  }

  private var scanHits: [ScanHit] = []
  private var scanFilterDeviceId: Int?
  private var scanResult: FlutterResult?
  private var scanTimer: Timer?

  // 首次创建 central 时状态回调未到(state=unknown):起扫/连接挂起,
  // 等上电回调再执行(否则 app 存活期第一次 BLE 操作必吃 bluetoothOff 假错)。
  private var pendingStart: [() -> Void] = []

  private var pendingConnect: FlutterResult?
  private var pendingReads: [CBUUID: FlutterResult] = [:]
  private var pendingWrites: [CBUUID: FlutterResult] = [:]
  private var pendingNotifies: [CBUUID: FlutterResult] = [:]
  private var servicesPendingDiscovery = Set<CBUUID>()

  // MARK: - FlutterStreamHandler

  public func onListen(withArguments _: Any?, eventSink sink: @escaping FlutterEventSink)
    -> FlutterError? {
    self.sink = sink
    return nil
  }

  public func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: - MethodChannel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(ensureCentral().state == .poweredOn)
    case "scan":
      startScan(timeoutSeconds: argInt(call, "seconds") ?? 10, filterDeviceId: nil, result: result)
    case "scanForDeviceId":
      startScan(timeoutSeconds: argInt(call, "seconds") ?? 10, filterDeviceId: argInt(call, "deviceId"), result: result)
    case "stopScan":
      endScan()
      result(nil)
    case "connectPaired":
      connectPaired(call.arguments as? String, result: result)
    case "setNotify":
      setNotify(call.arguments as? String, result: result)
    case "read":
      read(call.arguments as? String, result: result)
    case "write":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "badArgs", message: "write 参数须为 Map", details: nil))
        return
      }
      write(uuid: args["uuid"] as? String,
            data: (args["data"] as? FlutterStandardTypedData)?.data ?? Data(),
            withoutResponse: args["withoutResponse"] as? Bool ?? false,
            result: result)
    case "disconnect":
      disconnect(result: result)
    case "openBluetoothSettings":
      openBluetoothSettings(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensureCentral() -> CBCentralManager {
    if let central { return central }
    let manager = CBCentralManager(delegate: self, queue: nil)
    central = manager
    return manager
  }

  private func argInt(_ call: FlutterMethodCall, _ key: String) -> Int? {
    (call.arguments as? [String: Any])?[key] as? Int
  }

  // MARK: - 扫描

  private func startScan(timeoutSeconds: Int, filterDeviceId: Int?, result: @escaping FlutterResult) {
    if scanResult != nil {
      // 旧扫描在途(多为注入驱动退避轮的 scanForDeviceId):先收掉再起新扫
      // —— 旧调用方拿到当前已见列表按无/有命中处理,均无害;否则 busy
      // 会卡到旧超时才放行(真机踩过:重进配对页首扫必 busy)。
      endScan()
    }
    let central = ensureCentral()
    guard central.state != .unknown else {
      pendingStart.append { [weak self] in
        self?.startScan(timeoutSeconds: timeoutSeconds,
                        filterDeviceId: filterDeviceId, result: result)
      }
      return
    }
    guard central.state == .poweredOn else {
      result(FlutterError(code: "bluetoothOff", message: "蓝牙不可用(state=\(stateName(central.state)))", details: nil))
      return
    }
    scanResult = result
    scanFilterDeviceId = filterDeviceId
    scanHits.removeAll()
    central.scanForPeripherals(withServices: nil)
    scanTimer?.invalidate()
    scanTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeoutSeconds), repeats: false) { [weak self] _ in
      self?.endScan()
    }
  }

  private func endScan() {
    scanTimer?.invalidate()
    scanTimer = nil
    central?.stopScan()
    scanFilterDeviceId = nil
    guard let result = scanResult else { return }
    scanResult = nil
    result(scanHits.map { hit -> [String: Any] in
      ["name": hit.name,
       "uuid": hit.peripheral.identifier.uuidString.lowercased(),
       "rssi": hit.rssi,
       "mfg": FlutterStandardTypedData(bytes: hit.mfg)]
    })
  }

  // MARK: - 连接 / GATT

  private func connectPaired(_ uuidString: String?, result: @escaping FlutterResult) {
    let central = ensureCentral()
    guard central.state != .unknown else {
      pendingStart.append { [weak self] in
        self?.connectPaired(uuidString, result: result)
      }
      return
    }
    guard central.state == .poweredOn else {
      result(FlutterError(code: "bluetoothOff", message: "蓝牙不可用(state=\(stateName(central.state)))", details: nil))
      return
    }
    guard let uuidString, let uuid = UUID(uuidString: uuidString) else {
      result(FlutterError(code: "badArgs", message: "connectPaired 须传 peripheral uuid", details: nil))
      return
    }
    guard peripheral == nil else {
      result(FlutterError(code: "busy", message: "已有连接在途,先 disconnect", details: nil))
      return
    }
    let known = central.retrievePeripherals(withIdentifiers: [uuid]).first
      ?? scanHits.first { $0.peripheral.identifier == uuid }?.peripheral
    guard let target = known else {
      result(FlutterError(code: "notFound", message: "系统内无此设备标识:\(uuidString)", details: nil))
      return
    }
    endScan()  // 连接前收掉在途扫描(iOS 扫描中发起连接易抖)
    pendingConnect = result
    central.connect(target)
  }

  private func setNotify(_ uuidString: String?, result: @escaping FlutterResult) {
    guard let characteristic = findCharacteristic(uuidString) else {
      result(FlutterError(code: "notFound", message: "特征不存在:\(uuidString ?? "")", details: nil))
      return
    }
    pendingNotifies[characteristic.uuid] = result
    peripheral?.setNotifyValue(true, for: characteristic)
  }

  private func read(_ uuidString: String?, result: @escaping FlutterResult) {
    guard let characteristic = findCharacteristic(uuidString) else {
      result(FlutterError(code: "notFound", message: "特征不存在:\(uuidString ?? "")", details: nil))
      return
    }
    guard pendingReads[characteristic.uuid] == nil else {
      result(FlutterError(code: "busy", message: "同特征已有读在途", details: nil))
      return
    }
    pendingReads[characteristic.uuid] = result
    peripheral?.readValue(for: characteristic)
  }

  private func write(uuid: String?, data: Data, withoutResponse: Bool, result: @escaping FlutterResult) {
    guard let characteristic = findCharacteristic(uuid) else {
      result(FlutterError(code: "notFound", message: "特征不存在:\(uuid ?? "")", details: nil))
      return
    }
    if withoutResponse {
      peripheral?.writeValue(data, for: characteristic, type: .withoutResponse)
      result(nil)
      return
    }
    guard pendingWrites[characteristic.uuid] == nil else {
      result(FlutterError(code: "busy", message: "同特征已有写在途", details: nil))
      return
    }
    pendingWrites[characteristic.uuid] = result
    peripheral?.writeValue(data, for: characteristic, type: .withResponse)
  }

  private func disconnect(result: @escaping FlutterResult) {
    if let peripheral {
      central?.cancelPeripheralConnection(peripheral)
      self.peripheral = nil  // 立即释放:随后的 connect 不再撞 busy 守卫
    }
    result(nil)
  }

  /// 直达系统蓝牙设置页(App-Prefs 私有 scheme,新 iOS 可能失效 →
  /// 回落本 app 设置页);result = 是否直达蓝牙页成功。
  private func openBluetoothSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: "App-Prefs:root=Bluetooth") else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { ok in
      if ok {
        result(true)
        return
      }
      if let appSettings = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(appSettings, options: [:])
      }
      result(false)
    }
  }

  private func findCharacteristic(_ uuidString: String?) -> CBCharacteristic? {
    guard let uuidString else { return nil }
    let uuid = CBUUID(string: uuidString)
    for service in peripheral?.services ?? [] {
      if let characteristic = service.characteristics?.first(where: { $0.uuid == uuid }) {
        return characteristic
      }
    }
    return nil
  }

  // MARK: - CBCentralManagerDelegate

  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    emit(["type": "state", "state": stateName(central.state)])
    if central.state != .unknown, !pendingStart.isEmpty {
      let queued = pendingStart
      pendingStart.removeAll()
      // poweredOn → 真正起扫/连接;其余态走内部 guard 原路回错。
      for start in queued { start() }
    }
    if central.state != .poweredOn, scanResult != nil {
      scanTimer?.invalidate()
      scanTimer = nil
      scanFilterDeviceId = nil
      scanResult?(FlutterError(code: "bluetoothOff",
                               message: "蓝牙未开启(state=\(stateName(central.state)))", details: nil))
      scanResult = nil
    }
  }

  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                             advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
    if let filter = scanFilterDeviceId {
      // 重连过滤:厂商数据 = 0x0399(小端 99 03)+ deviceId 小端 4B。
      let le = withUnsafeBytes(of: UInt32(filter).littleEndian, Array.init)
      guard mfg.count >= 6, mfg[0] == 0x99, mfg[1] == 0x03,
            Array(mfg[2...5]) == le else { return }
    } else {
      // 配对扫描只收尼康机身:名 Z 开头(Z f_8014411 系)或 0x0399 厂商
      // 数据 —— 全量列表只会让用户点到耳机/手表上白连一场。
      guard name.hasPrefix("Z ") || name.contains("Z_f")
          || (mfg.count >= 2 && mfg[0] == 0x99 && mfg[1] == 0x03)
      else { return }
    }
    if let index = scanHits.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
      scanHits[index] = ScanHit(peripheral: peripheral, name: name, rssi: RSSI.intValue, mfg: mfg)
    } else {
      scanHits.append(ScanHit(peripheral: peripheral, name: name, rssi: RSSI.intValue, mfg: mfg))
    }
    emit(["type": "discovered",
          "name": name,
          "uuid": peripheral.identifier.uuidString.lowercased(),
          "rssi": RSSI.intValue,
          "mfg": FlutterStandardTypedData(bytes: mfg)])
    if scanFilterDeviceId != nil {
      endScan()  // 重连扫描:首个 deviceId 命中即收,不等满窗
    }
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    self.peripheral = peripheral
    peripheral.delegate = self
    servicesPendingDiscovery.removeAll()
    peripheral.discoverServices(nil)
  }

  public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                             error: Error?) {
    pendingConnect?(FlutterError(code: "connectFailed",
                                 message: error.map(String.init(describing:)) ?? "连接失败", details: nil))
    pendingConnect = nil
    emit(["type": "error", "code": "connectFailed",
          "message": error.map(String.init(describing:)) ?? "连接失败"])
  }

  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                             error: Error?) {
    if self.peripheral?.identifier == peripheral.identifier {
      self.peripheral = nil
      failPendingOps("disconnected")
    }
    emit(["type": "disconnected", "uuid": peripheral.identifier.uuidString.lowercased()])
  }

  // MARK: - CBPeripheralDelegate

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      pendingConnect?(FlutterError(code: "discoveryFailed", message: String(describing: error), details: nil))
      pendingConnect = nil
      return
    }
    let services = peripheral.services ?? []
    servicesPendingDiscovery = Set(services.map(\.uuid))
    if services.isEmpty {
      finishConnect(peripheral)
      return
    }
    for service in services {
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                         error: Error?) {
    servicesPendingDiscovery.remove(service.uuid)
    if servicesPendingDiscovery.isEmpty {
      finishConnect(peripheral)
    }
  }

  private func finishConnect(_ peripheral: CBPeripheral) {
    var characteristics: [String: String] = [:]
    for service in peripheral.services ?? [] {
      for characteristic in service.characteristics ?? [] {
        var props: [String] = []
        if characteristic.properties.contains(.read) { props.append("read") }
        if characteristic.properties.contains(.write) { props.append("write") }
        if characteristic.properties.contains(.writeWithoutResponse) { props.append("writeWithoutResponse") }
        if characteristic.properties.contains(.notify) { props.append("notify") }
        if characteristic.properties.contains(.indicate) { props.append("indicate") }
        characteristics[characteristic.uuid.uuidString.lowercased()] = props.joined(separator: "|")
      }
    }
    emit(["type": "connected",
          "uuid": peripheral.identifier.uuidString.lowercased(),
          "characteristics": characteristics,
          "mtu": peripheral.maximumWriteValueLength(for: .withoutResponse)])
    pendingConnect?(nil)
    pendingConnect = nil
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                         error: Error?) {
    if let result = pendingReads.removeValue(forKey: characteristic.uuid) {
      if let error {
        result(FlutterError(code: "readFailed", message: String(describing: error), details: nil))
      } else {
        result(FlutterStandardTypedData(bytes: characteristic.value ?? Data()))
      }
    }
    // indicate/notify 数据推事件;读回不推(0x2004 等只读特征走 read 返回)。
    if characteristic.isNotifying {
      emit(["type": "notify",
            "uuid": characteristic.uuid.uuidString.lowercased(),
            "data": FlutterStandardTypedData(bytes: characteristic.value ?? Data())])
    } else if let error, pendingReads[characteristic.uuid] == nil {
      emit(["type": "error", "code": "valueFailed",
            "uuid": characteristic.uuid.uuidString.lowercased(),
            "message": String(describing: error)])
    }
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                         error: Error?) {
    if let result = pendingNotifies.removeValue(forKey: characteristic.uuid) {
      if let error {
        result(FlutterError(code: "notifyFailed", message: String(describing: error), details: nil))
      } else {
        result(nil)
      }
    }
  }

  public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                         error: Error?) {
    if let result = pendingWrites.removeValue(forKey: characteristic.uuid) {
      if let error {
        result(FlutterError(code: "writeFailed", message: String(describing: error), details: nil))
      } else {
        result(nil)
      }
    }
  }

  // MARK: - Helpers

  private func failPendingOps(_ code: String) {
    for (_, result) in pendingReads {
      result(FlutterError(code: code, message: "连接已断开", details: nil))
    }
    pendingReads.removeAll()
    for (_, result) in pendingWrites {
      result(FlutterError(code: code, message: "连接已断开", details: nil))
    }
    pendingWrites.removeAll()
    for (_, result) in pendingNotifies {
      result(FlutterError(code: code, message: "连接已断开", details: nil))
    }
    pendingNotifies.removeAll()
  }

  private func emit(_ payload: [String: Any]) {
    sink?(payload)
  }

  private func stateName(_ state: CBManagerState) -> String {
    switch state {
    case .poweredOn: return "poweredOn"
    case .poweredOff: return "poweredOff"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    case .resetting: return "resetting"
    case .unknown: return "unknown"
    @unknown default: return "unknown"
    }
  }
}
