//
//  KlcxkjBleCentral.swift
//  CoreBluetooth 封装：扫描 / 连接 / 特征读写 / 命令-应答
//
//  ⚠️ iOS 关键差异（与 Android 版不同）：
//    iOS 拿不到外设 MAC 地址（隐私限制），CBPeripheral.identifier 是系统随机 UUID。
//    解决办法（本项目已实测确认）：
//        设备 SN 与 MAC 等价 —— MAC = SN 按字节加冒号
//        （实测：SN C47F0E26992B  ↔  MAC C4:7F:0E:26:99:2B）
//    因此只要拿到 SN 即可推导出服务端所需的 macAddress。
//    SN 来源优先级：
//        ① 广播数据（厂商数据/服务数据）里出现的 12 位 hex  → 自动提取
//        ② 设备机身标签上的序列号 → 界面手输
//        ③ 服务端 /device/info/sn?snCode=xxx 反查
//
import Foundation
import CoreBluetooth

// MARK: - 扫描到的设备

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID                 // peripheral.identifier（iOS 会话内稳定）
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    /// 从广播里猜出来的 SN（12 位 hex）；猜不到则为 nil
    let guessedSN: String?
    /// 广播原始数据（供界面排查）
    let advSummary: String

    /// SN → MAC（加冒号）
    var derivedMAC: String? {
        guard let sn = guessedSN, sn.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { i -> String in
            let s = sn.index(sn.startIndex, offsetBy: i)
            let e = sn.index(s, offsetBy: 2)
            return String(sn[s..<e])
        }.joined(separator: ":")
    }

    static func == (l: DiscoveredDevice, r: DiscoveredDevice) -> Bool { l.id == r.id }
}

// MARK: - 连接状态

enum BleConnectionState: Equatable {
    case idle, connecting, ready, failed(String)
}

// MARK: - 主控制器

@MainActor
final class KlcxkjBleCentral: NSObject, ObservableObject {

    // GATT（水表固定 UUID）
    static let serviceUUID = CBUUID(string: "0000FF00-0000-1000-8000-00805F9B34FB")
    static let notifyUUID  = CBUUID(string: "0000FF01-0000-1000-8000-00805F9B34FB")
    static let writeUUID   = CBUUID(string: "0000FF02-0000-1000-8000-00805F9B34FB")

    @Published var devices: [DiscoveredDevice] = []
    @Published var isScanning = false
    @Published var connState: BleConnectionState = .idle
    @Published var log: String = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var rxBuf = Data()
    private var frames: [(cmd: UInt8, payload: Data)] = []

    private var connectCont: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func append(_ s: String) {
        log += s + "\n"
        if log.count > 20000 { log = String(log.suffix(15000)) }
    }

    // ── 扫描 ──
    func startScan() {
        guard central.state == .poweredOn else {
            append("蓝牙不可用：\(stateText(central.state))")
            return
        }
        devices.removeAll()
        isScanning = true
        // 不过滤 service（部分水表广播里不带 FF00），靠名字/广播内容筛
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        append("开始扫描…（找名字含 KLCXKJ 或广播含 12 位 SN 的设备）")
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        append("扫描停止，共 \(devices.count) 个候选")
    }

    // ── 连接 ──
    func connect(_ d: DiscoveredDevice) async -> Bool {
        if case .ready = connState { append("已连接，忽略"); return true }
        connState = .connecting
        peripheral = d.peripheral
        d.peripheral.delegate = self
        append("连接 \(d.name) (\(d.id.uuidString.prefix(8))…)")
        central.connect(d.peripheral, options: nil)
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            connectCont = c
            // 15 秒超时
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, let cont = self.connectCont else { return }
                self.connectCont = nil
                self.connState = .failed("连接超时")
                self.append("连接超时")
                cont.resume(returning: false)
            }
        }
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        connState = .idle
        rxBuf.removeAll()
        frames.removeAll()
    }

    // ── 命令 ──
    private func drain() {
        frames.removeAll()
        rxBuf.removeAll()
    }

    /// 发命令并等对应 cmd 的应答
    func send(cmd: UInt8, data: Data = Data(), reply: UInt8? = nil, timeout: TimeInterval = 8) async -> Data? {
        guard let p = peripheral, let wc = writeChar, wc.properties.contains(.write) || wc.properties.contains(.writeWithoutResponse) else {
            append("未就绪或无写特征")
            return nil
        }
        drain()   // 先清残留：设备会主动推上一笔未结算帧
        let wire = BleFrameCodec.cmdToWire(cmd: cmd, data: data)
        p.writeValue(wire, for: wc, type: .withoutResponse)
        let want = reply ?? cmd
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let i = frames.firstIndex(where: { $0.cmd == want }) {
                let f = frames.remove(at: i)
                return f.payload
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        append("等应答超时 cmd=0x\(String(format: "%02X", cmd))")
        return nil
    }

    func query() async -> DeviceQueryState? {
        guard let p = await send(cmd: BleCmd.query) else { return nil }
        return DeviceQueryState.parse(p)
    }

    func writeRate(_ down: Data) async -> Bool {
        guard let p = await send(cmd: BleCmd.rate, data: down) else { return false }
        return p.first == BleFrameCodec.ackOK
    }

    func closeValve() async -> Bool {
        guard let p = await send(cmd: BleCmd.close) else { return false }
        return p.first == BleFrameCodec.ackOK
    }

    func collect() async -> Data? {
        await send(cmd: BleCmd.collect)
    }

    func writeBack(_ d: Data) async -> Bool {
        guard let p = await send(cmd: BleCmd.writeBack, data: d) else { return false }
        return p.first == BleFrameCodec.ackOK
    }

    // ── 工具 ──
    private func stateText(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "已开启"
        case .poweredOff: return "未开启"
        case .unauthorized: return "未授权（请在设置里允许蓝牙）"
        case .unsupported: return "不支持"
        default: return "未知"
        }
    }

    /// 从广播数据里猜 SN（12 位 hex，常以 C47F0 开头）
    static func guessSN(from adv: [String: Any]) -> String? {
        var blobs: [Data] = []
        if let m = adv[CBAdvertisementDataManufacturerDataKey] as? Data { blobs.append(m) }
        if let sd = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            blobs.append(contentsOf: sd.values)
        }
        if let ln = adv[CBAdvertisementDataLocalNameKey] as? String, let d = ln.data(using: .utf8) {
            blobs.append(d)
        }
        for b in blobs {
            let hex = b.map { String(format: "%02X", $0) }.joined()
            // 找 12 位连续 hex，优先 C47F0 开头（该厂商 OUI）
            if let r = hex.range(of: "C47F0[0-9A-F]{7}", options: .regularExpression) {
                return String(hex[r])
            }
        }
        return nil
    }

    static func advSummary(_ adv: [String: Any]) -> String {
        var parts: [String] = []
        if let n = adv[CBAdvertisementDataLocalNameKey] as? String { parts.append("name=\(n)") }
        if let m = adv[CBAdvertisementDataManufacturerDataKey] as? Data {
            parts.append("mfr=\(m.map { String(format: "%02X", $0) }.joined())")
        }
        if let sd = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (k, v) in sd { parts.append("svc:\(k.uuidString.prefix(8))=\(v.map { String(format: "%02X", $0) }.joined())") }
        }
        if let s = adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            parts.append("uuids=\(s.map { $0.uuidString.prefix(8) }.joined(separator: ","))")
        }
        return parts.joined(separator: " | ")
    }
}

// MARK: - CBCentralManagerDelegate

extension KlcxkjBleCentral: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            append("蓝牙状态：\(stateText(central.state))")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        let sn = KlcxkjBleCentral.guessSN(from: advertisementData)
        let summary = KlcxkjBleCentral.advSummary(advertisementData)

        // 只收：名字像水表 或 广播里有 SN
        let isWater = name.lowercased().contains("klcxkj") || name.lowercased().contains("water")
        guard isWater || sn != nil else { return }

        Task { @MainActor in
            if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
                devices[i] = DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral,
                                              name: name.isEmpty ? "(无名)" : name,
                                              rssi: RSSI.intValue, guessedSN: sn, advSummary: summary)
            } else {
                devices.append(DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral,
                                                name: name.isEmpty ? "(无名)" : name,
                                                rssi: RSSI.intValue, guessedSN: sn, advSummary: summary))
                append("发现：\(name)  RSSI=\(RSSI)  SN=\(sn ?? "未识别")")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            append("已连接，发现服务…")
            peripheral.discoverServices([KlcxkjBleCentral.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            append("连接失败：\(error?.localizedDescription ?? "未知")")
            connState = .failed(error?.localizedDescription ?? "连接失败")
            connectCont?.resume(returning: false)
            connectCont = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            append("已断开\(error.map { "（\($0.localizedDescription)）" } ?? "")")
            if case .ready = connState { connState = .idle }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension KlcxkjBleCentral: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svcs = peripheral.services else { return }
        for s in svcs where s.uuid == KlcxkjBleCentral.serviceUUID {
            peripheral.discoverCharacteristics(
                [KlcxkjBleCentral.notifyUUID, KlcxkjBleCentral.writeUUID], for: s)
            return
        }
        Task { @MainActor in
            append("该设备无水控服务 FF00（不是蓝牙水表）")
            connState = .failed("无水控服务")
            connectCont?.resume(returning: false)
            connectCont = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == KlcxkjBleCentral.notifyUUID { notifyChar = c }
            if c.uuid == KlcxkjBleCentral.writeUUID { writeChar = c }
        }
        if let n = notifyChar {
            peripheral.setNotifyValue(true, for: n)
        } else {
            Task { @MainActor in
                append("未找到 FF01 通知特征")
                connState = .failed("缺 FF01")
                connectCont?.resume(returning: false)
                connectCont = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if characteristic.uuid == KlcxkjBleCentral.notifyUUID {
                if error == nil {
                    append("通知已开启，连接就绪")
                    connState = .ready
                    connectCont?.resume(returning: true)
                } else {
                    append("开通知失败：\(error?.localizedDescription ?? "")")
                    connState = .failed("通知开启失败")
                    connectCont?.resume(returning: false)
                }
                connectCont = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid == KlcxkjBleCentral.notifyUUID,
              let d = characteristic.value else { return }
        Task { @MainActor in
            rxBuf.append(d)
            // 按 '\n' 切帧
            while let r = BleFrameCodec.parseWire(rxBuf) {
                rxBuf.removeSubrange(0..<r.consumed)
                frames.append((r.cmd, r.payload))
            }
        }
    }
}
