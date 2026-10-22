// Nikon BLE GATT 全量发现(CLI):扫描 → 连接(复用已配对身份的广播)
// → 枚举全部服务/特征(属性/句柄)→ 打印退出。
// 用途:确认配对态下除 0xDE00(smart 模式)之外是否还有命令服务
// (WiFi 激活 op 的候选面)。参考 tools/ble_pair/z_ble_pair(源码
// 已失,本件独立重写,只做只读发现,不发任何写命令)。
import Foundation
import CoreBluetooth

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var done = false
    private var seenNames: Set<String> = []
    private let target = "Z_f_"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            print("BT 不可用: \(central.state.rawValue)")
            exit(2)
        }
        print("扫描 30 秒(名含 \(target))…")
        central.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.done else { return }
            print("未发现相机(配对画面可能没开/广播窗口已关)")
            exit(1)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        // 重连态广播 = 0x0399 厂商数据(LE)+ 4B device + 0x00,可能无名;
        // 配对态广播带名。两条件都收。
        var isNikon = name.contains(target)
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfg.count >= 7, mfg[0] == 0x99, mfg[1] == 0x03 {
            isNikon = true
            print("  (0x0399 厂商数据: \(mfg.map { String(format: "%02x", $0) }.joined(separator: " ")))")
        }
        if !isNikon {
            if !name.isEmpty, !seenNames.contains(name) {
                seenNames.insert(name)
                print("  (他机: \(name))")
            }
            return
        }
        print("发现 \(name.isEmpty ? "(无名,0x0399)" : name) RSSI=\(RSSI) — 连接(全量发现)…")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("已连接,发现服务…")
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("服务发现错误: \(error)") }
        for service in peripheral.services ?? [] {
            print("SERVICE \(service.uuid.uuidString) (\(service.uuid.description))")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if (peripheral.services ?? []).isEmpty {
            readAllThenFinish()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error { print("  特征发现错误: \(error)") }
        print("  CHR in service \(service.uuid.uuidString):")
        for c in service.characteristics ?? [] {
            var props: [String] = []
            if c.properties.contains(.broadcast) { props.append("broadcast") }
            if c.properties.contains(.read) { props.append("read") }
            if c.properties.contains(.writeWithoutResponse) { props.append("writeNoRsp") }
            if c.properties.contains(.write) { props.append("write") }
            if c.properties.contains(.notify) { props.append("notify") }
            if c.properties.contains(.indicate) { props.append("indicate") }
            print("    \(c.uuid.uuidString)  [\(props.joined(separator: " "))]")
        }
        if service.characteristics?.isEmpty ?? true {
            print("    (无特征)")
        }
        // 全部服务都发现完则读值后收尾
        if let services = peripheral.services,
           services.allSatisfy({ $0.characteristics != nil }) {
            readAllThenFinish()
        }
    }

    private var readPending = 0

    private func readAllThenFinish() {
        guard !done else { return }
        var targets: [(CBCharacteristic)] = []
        for service in peripheral?.services ?? [] {
            for c in service.characteristics ?? [] where c.properties.contains(.read) {
                targets.append(c)
            }
        }
        if targets.isEmpty { finish() }
        readPending = targets.count
        for c in targets {
            peripheral?.readValue(for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let val = characteristic.value ?? Data()
        let hex = val.map { String(format: "%02x", $0) }.joined(separator: " ")
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -.")
        let ascii = val.map { UnicodeScalar($0) }
            .filter { allowed.contains($0 ?? " " ) }
        print("  READ \(characteristic.uuid.uuidString)(\(val.count)B): \(hex)"
            + (ascii.isEmpty ? "" : "  ascii='\(String(String.UnicodeScalarView(ascii.compactMap { $0 })))'"))
        readPending -= 1
        if readPending <= 0 { finish() }
    }

    private func finish() {
        guard !done else { return }
        done = true
        print("── 发现完成 ──")
        exit(0)
    }
}

let probe = Probe()
dispatchMain()
