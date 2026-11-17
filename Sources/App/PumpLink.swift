import Foundation
import CoreBluetooth
import Combine
import PumpKit

/// 与迈世通泵的 BLE 链路（等价 Android 的 CEL + MDCS + BGP 的合并精简版）
/// 服务: FFE0 (读) / FFE5 (写)；特征: FFE4 (notify) / FFE9 (write)
@MainActor
final class PumpLink: NSObject, ObservableObject {

    // MARK: - 对外状态

    enum LinkState: Equatable {
        case idle, poweredOff, scanning, connecting(String), ready
        case failed(String)
    }

    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    @Published private(set) var state: LinkState = .idle
    @Published private(set) var devices: [Device] = []
    @Published private(set) var status: PumpStatus?
    @Published private(set) var lastMessage: String = ""
    @Published private(set) var log: [String] = []

    /// 当前连接泵的蓝牙名，同时作为 12 字节 serial 使用
    private(set) var pumpSerial: String = ""

    // MARK: - CoreBluetooth

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var rxBuffer: [UInt8] = []
    private var nextMsgId: UInt16 = 1
    private var statusTimer: Timer?

    private static let serviceRead = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    private static let serviceWrite = CBUUID(string: "0000FFE5-0000-1000-8000-00805F9B34FB")
    private static let charNotify = CBUUID(string: "0000FFE4-0000-1000-8000-00805F9B34FB")
    private static let charWrite = CBUUID(string: "0000FFE9-0000-1000-8000-00805F9B34FB")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 扫描 / 连接

    func startScan() {
        guard central.state == .poweredOn else {
            state = .poweredOff
            return
        }
        devices.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        append("开始扫描")
    }

    func stopScan() {
        central.stopScan()
        if case .scanning = state { state = .idle }
    }

    func connect(_ device: Device) {
        central.stopScan()
        state = .connecting(device.name)
        let p = central.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let target = p else {
            state = .failed("无法获取设备句柄，请重新扫描")
            return
        }
        peripheral = target
        target.delegate = self
        central.connect(target, options: nil)
    }

    func disconnect() {
        statusTimer?.invalidate()
        statusTimer = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        state = .idle
    }

    // MARK: - 发送

    @discardableResult
    func send(_ cmd: AppFrame.Cmd, rw: AppFrame.RW = .write, payload: [UInt8] = []) -> UInt16 {
        guard let p = peripheral, let ch = writeChar else {
            append("未连接，命令被丢弃")
            return 0
        }
        let msgId = nextMsgId
        nextMsgId = nextMsgId == UInt16.max ? 1 : nextMsgId + 1
        let frame = AppFrame(rw: rw, cmd: cmd, serial: pumpSerial, payload: payload, msgId: msgId)
        let bytes = frame.encode()
        append("→ \(Bytes.hex(bytes))")
        p.writeValue(Data(bytes), for: ch, type: .withResponse)
        return msgId
    }

    func requestStatus() {
        send(.fullStatus, rw: .read)
    }

    func deliverBolus(_ units: Double) {
        send(.bolus, payload: PumpCommand.bolus(units))
        append("已发送大剂量 \(units) U")
    }

    func cancelBolus() {
        send(.bolus, payload: PumpCommand.cancelBolus())
        append("已发送「取消大剂量」")
    }

    func setTBR(percent: Int, minutes: Int) {
        send(.tbr, payload: PumpCommand.tbr(percent: percent, minutes: minutes))
        append("已发送 TBR \(percent)% / \(minutes) 分钟")
    }

    func cancelTBR() {
        send(.tbr, payload: PumpCommand.cancelTBR())
        append("已取消 TBR")
    }

    func stopPump() {
        send(.startStop, payload: PumpCommand.startStop(stop: true))
        append("已发送「停止输注」")
    }

    func startPump() {
        send(.startStop, payload: PumpCommand.startStop(stop: false))
        append("已发送「启动输注」")
    }

    func setAlert(_ text: String) {
        lastMessage = "⚠️ " + text
        append("⚠️ " + text)
    }

    func syncTime() {
        send(.timeSync, payload: PumpCommand.timeSync())
        append("已同步手机时间")
    }

    // MARK: - 收帧

    private func ingest(_ data: [UInt8]) {
        rxBuffer.append(contentsOf: data)
        while rxBuffer.count >= 3 {
            guard rxBuffer[0] == 0x55 else {
                // 丢掉乱码直到下一个 0x55
                if let idx = rxBuffer.firstIndex(of: 0x55) { rxBuffer.removeFirst(idx) } else { rxBuffer.removeAll() }
                continue
            }
            let len = Int(rxBuffer[1]) | (Int(rxBuffer[2]) << 8)
            guard len >= 23, len <= 512 else {
                rxBuffer.removeAll()
                continue
            }
            guard rxBuffer.count >= len else { return }   // 等后续分包
            let frameBytes = Array(rxBuffer[0..<len])
            rxBuffer.removeFirst(len)
            handle(frameBytes)
        }
    }

    private func handle(_ bytes: [UInt8]) {
        append("← \(Bytes.hex(bytes))")
        guard let frame = AppFrame.decode(bytes) else {
            append("帧解析失败")
            return
        }
        if !frame.crcOK { append("⚠️ CRC 校验失败") }

        switch frame.cmd {
        case .fullStatus:
            if let s = PumpStatus.parse(frame.payload) {
                status = s
                lastMessage = "状态已更新"
            } else {
                lastMessage = "状态解析失败"
            }
        case .accOK, .executed:
            lastMessage = "泵已接受"
        case .executing:
            lastMessage = "执行中…"
        case .accError:
            lastMessage = "泵拒绝：参数错误"
        case .denied:
            lastMessage = "泵拒绝：当前不允许该操作"
        default:
            lastMessage = "收到 0x\(String(format: "%04X", frame.rawCmd))"
        }
    }

    private func append(_ s: String) {
        let t = DateFormatter()
        t.dateFormat = "HH:mm:ss"
        log.insert("\(t.string(from: Date())) \(s)", at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
    }
}

// MARK: - CBCentralManagerDelegate

extension PumpLink: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if case .poweredOff = self.state { self.state = .idle }
            case .poweredOff:
                self.state = .poweredOff
            case .unauthorized:
                self.state = .failed("蓝牙权限被拒绝，请到设置里允许")
            default:
                self.state = .failed("蓝牙不可用")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        // 泵名形如 IP4-1234567 / IP4.1234567
        guard name.range(of: #"^IP\d[\.\-]"#, options: .regularExpression) != nil else { return }
        Task { @MainActor in
            let dev = Device(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let i = self.devices.firstIndex(where: { $0.id == dev.id }) {
                self.devices[i] = dev
            } else {
                self.devices.append(dev)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.append("已连接，发现服务…")
            peripheral.discoverServices([PumpLink.serviceRead, PumpLink.serviceWrite])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.state = .failed("连接失败：\(error?.localizedDescription ?? "未知错误")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.statusTimer?.invalidate()
            self.writeChar = nil
            self.notifyChar = nil
            self.state = .idle
            self.append("连接已断开 \(error?.localizedDescription ?? "")")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PumpLink: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                if c.uuid == PumpLink.charNotify {
                    self.notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                } else if c.uuid == PumpLink.charWrite {
                    self.writeChar = c
                }
            }
            if self.writeChar != nil && self.notifyChar != nil && self.state != .ready {
                self.pumpSerial = peripheral.name ?? ""
                self.state = .ready
                self.append("就绪，泵 serial = \(self.pumpSerial)")
                self.requestStatus()
                self.startAutoRefresh()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let e = error { self.append("开启通知失败：\(e.localizedDescription)") }
            else { self.append("通知已开启") }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let d = characteristic.value else { return }
        let bytes = [UInt8](d)
        Task { @MainActor in self.ingest(bytes) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            Task { @MainActor in self.append("写入失败：\(e.localizedDescription)") }
        }
    }
}

// MARK: - 定时刷新

extension PumpLink {
    private func startAutoRefresh() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestStatus() }
        }
    }
}
