import Foundation
import CoreBluetooth
import Combine

/// 与迈世通泵的 BLE 链路（等价 Android 的 CEL + MDCS + BGP 合并精简版）
/// 服务: FFE0(读) / FFE5(写)；特征: FFE4(notify) / FFE9(write with response)
@MainActor
final class PumpLink: NSObject, ObservableObject {

    enum LinkState: Equatable {
        case idle, poweredOff, scanning, connecting(String), ready
        case failed(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let outbound: Bool
        let stamp = Date()
    }

    // MARK: - 对外状态

    @Published private(set) var state: LinkState = .idle
    @Published private(set) var devices: [Device] = []
    @Published private(set) var status: PumpStatus?
    /// 官方回帧解析出的真实设备状态（电量/余量/时钟/三餐预设）
    @Published private(set) var officialStatus: OfficialStatus?
    @Published private(set) var lastMessage: String = ""
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var history: [HistoryRecord] = []
    @Published private(set) var lastBolus: LastBolus?
    @Published private(set) var basalState: BasalState?
    @Published private(set) var delivered: Double?
    /// 进行中的大剂量估算：已输注 / 总量（0.5U 一档，避免看起来比泵还准）
    @Published private(set) var bolusProgrammed: Double = 0
    @Published private(set) var bolusEstimated: Double = 0
    /// 泵回报的真实输注进度（优先于估算显示）
    @Published private(set) var bolusProgress: Double?
    @Published private(set) var bolusRunning: Bool = false
    /// 泵的输注速度（U/秒），默认按常见管路泵 0.5U/6s 估算
    @Published var bolusUnitsPerSecond: Double = UserDefaults.standard.object(forKey: "bolus.ups") as? Double ?? (0.5 / 6) {
        didSet { UserDefaults.standard.set(bolusUnitsPerSecond, forKey: "bolus.ups") }
    }
    private var bolusStart: Date?
    private var bolusTimer: Timer?
    @Published private(set) var alarmsRaw: String = ""
    @Published private(set) var primeRaw: String = ""
    @Published private(set) var lastRxAt: Date?
    @Published private(set) var lastReplyHex: String = ""
    @Published private(set) var lastValidFrameAt: Date?
    @Published private(set) var lastReplyCmd: UInt16 = 0
    @Published private(set) var negotiatedMTU: Int = 0

    private(set) var pumpSerial: String = ""
    private var lastKnownPeripheralID: UUID?

    /// 手动覆盖帧里的 12 字节 serial（留空则用蓝牙名）
    /// 只写不确认：泵不回帧也照发，命令按「已发送」处理，人工在泵屏幕核对
    @Published var fireAndForget: Bool = UserDefaults.standard.object(forKey: "ff.mode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fireAndForget, forKey: "ff.mode") }
    }

    @Published var serialOverride: String = UserDefaults.standard.string(forKey: "serial.override") ?? "" {
        didSet { UserDefaults.standard.set(serialOverride, forKey: "serial.override") }
    }

    var frameSerialForDisplay: String { frameSerial }

    private var frameSerial: String {
        let o = serialOverride.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty { return o }
        return PumpSerial.from(deviceName: pumpSerial)
    }

    /// 官方帧：无 0x01/msgId 尾，serial 用纯数字 + 0x00 补齐（实测官方 App 可通）
    let frameVariant: AppFrame.Variant = .official

    /// 给 UI 用的错误详情（CBError 只给 localizedDescription 太笼统）
    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var tip = ""
        if ns.domain == CBATTErrorDomain {
            switch ns.code {
            case 0x02: tip = "（读不允许）"
            case 0x03: tip = "（写不允许）"
            case 0x05: tip = "（链路未加密/未配对 → 去系统蓝牙里配对后重连）"
            case 0x0C: tip = "（需要更高安全等级）"
            case 0x0E: tip = "（需要加密）"
            default: tip = ""
            }
        }
        return "CBError \(ns.domain)/\(ns.code): \(ns.localizedDescription)\(tip)"
    }

    // MARK: - CoreBluetooth

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var rxBuffer: [UInt8] = []
    private var rxPackets = 0
    private var didLogWriteType = false
    /// 写入方式：默认带响应，能暴露加密/权限错误；泵只认 no-response 时可切
    @Published var writeWithoutResponse: Bool = UserDefaults.standard.object(forKey: "write.noresp.v2") as? Bool ?? false {
        didSet { UserDefaults.standard.set(writeWithoutResponse, forKey: "write.noresp.v2") }
    }
    private var nextMsgId: UInt16 = 1
    private var pollTimer: Timer?
    private var pendingHistory = false
    private var autoReconnect = false
    private var reconnectWork: DispatchWorkItem?
    private var probeWork: DispatchWorkItem?
    private var noReplyWork: DispatchWorkItem?
    private enum PendingRead: Equatable { case lastBolus, alarms, prime }
    private var pendingRead: PendingRead?
    private var pendingReadCmd: UInt16 = 0

    private static let serviceRead: [CBUUID] = [CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB"),
                                                CBUUID(string: "0000FFE5-0000-1000-8000-00805F9B34FB")]
    private static let charNotify = CBUUID(string: "0000FFE4-0000-1000-8000-00805F9B34FB")
    private static let charWrite = CBUUID(string: "0000FFE9-0000-1000-8000-00805F9B34FB")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 扫描 / 连接

    func startScan() {
        guard central.state == .poweredOn else { state = .poweredOff; return }
        devices.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        append("开始扫描", out: false)
    }

    func stopScan() {
        central.stopScan()
        if case .scanning = state { state = .idle }
    }

    func connect(_ device: Device) {
        central.stopScan()
        state = .connecting(device.name)
        lastKnownPeripheralID = device.id
        UserDefaults.standard.set(device.id.uuidString, forKey: "lastPeripheralID")
        guard let p = central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            state = .failed("无法获取设备句柄，请重新扫描"); return
        }
        peripheral = p
        p.delegate = self
        autoReconnect = true
        central.connect(p, options: nil)
    }

    /// 启动/蓝牙就绪后自动连上次的泵，省掉每次重连
    func autoConnectIfRemembered() {
        guard state == .idle else { return }
        if lastKnownPeripheralID == nil,
           let s = UserDefaults.standard.string(forKey: "lastPeripheralID"),
           let id = UUID(uuidString: s) {
            lastKnownPeripheralID = id
        }
        guard let id = lastKnownPeripheralID,
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        append("自动连接上次的泵：\(p.name ?? "-")", out: false)
        state = .connecting(p.name ?? "上次的泵")
        peripheral = p
        p.delegate = self
        autoReconnect = true
        central.connect(p, options: nil)
    }

    func connectLastKnown() {
        guard let id = lastKnownPeripheralID,
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripheral = p
        p.delegate = self
        autoReconnect = true
        state = .connecting(p.name ?? "上次的泵")
        central.connect(p, options: nil)
    }

    func disconnect() {
        autoReconnect = false
        reconnectWork?.cancel()
        pollTimer?.invalidate(); pollTimer = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; writeChar = nil; notifyChar = nil
        state = .idle
    }

    // MARK: - 发送

    @discardableResult
    private func write(_ cmd: AppFrame.Cmd, rw: AppFrame.RW, payload: [UInt8] = []) -> UInt16 {
        guard let p = peripheral, let ch = writeChar else {
            append("未连接，命令被丢弃", out: false); return 0
        }
        let msgId = nextMsgId
        nextMsgId = nextMsgId == UInt16.max ? 1 : nextMsgId + 1
        let frame = AppFrame(rw: rw, cmd: cmd, serial: frameSerial,
                             payload: payload, msgId: msgId, variant: frameVariant)
        let bytes = frame.encode()
        append("[官]" + Bytes.hex(bytes, separator: " "), out: true)
        if bytes.count > negotiatedMTU && negotiatedMTU > 0 {
            append("⚠️ 帧 \(bytes.count)B 超过协商上限 \(negotiatedMTU)B", out: false)
        }
        let useNoResp = writeWithoutResponse && ch.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = useNoResp ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: ch, type: type)
        if !didLogWriteType {
            didLogWriteType = true
            append("写入方式=\(useNoResp ? "无响应" : "带响应")", out: false)
        }
        if fireAndForget {
            lastMessage = "已发送（未确认）：请到泵屏幕核对"
        } else {
            armNoReplyGuard()
        }
        return msgId
    }

    // MARK: 命令

    func requestStatus() { write(.fullStatus, rw: .read) }

    /// 读大剂量记录：官方 cmd = {1, index}，index 0xAA 表示“最大索引”
    func readBolusIndex(_ index: UInt8 = 0xAA) {
        write(AppFrame.Cmd(rawValue: 0x0001 | (UInt16(index) << 8)), rw: .read)
        append("读大剂量记录 idx=0x\(String(format: "%02X", index))", out: false)
    }

    /// 读基础率模板：cmd = {2, 0xAA} → 0xAA02
    func readBasal() {
        write(AppFrame.Cmd(rawValue: 0xAA02), rw: .read)
        append("读基础率模板", out: false)
    }

    /// 读报警记录：cmd = {3, 0xAA} → 0xAA03
    func readAlarms() {
        write(AppFrame.Cmd(rawValue: 0xAA03), rw: .read)
        append("读报警记录", out: false)
    }

    func syncTime() {
        write(.timeSync, rw: .write, payload: PumpCommand.timeSync())
        append("已发送校时", out: true)
    }

    func deliverBolus(_ units: Double) {
        bolusProgress = nil
        write(.bolus, rw: .write, payload: PumpCommand.bolus(units))
        append("打药 \(units) U", out: false)
        startBolusTracking(units)
    }

    /// 按时间估算进度：0.5U 一档，取整到 0.5，避免显示虚假精度
    private func startBolusTracking(_ units: Double) {
        bolusTimer?.invalidate()
        bolusProgrammed = units
        bolusEstimated = 0
        bolusRunning = true
        bolusStart = Date()
        bolusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.bolusStart, self.bolusRunning else { return }
                let raw = Date().timeIntervalSince(start) * self.bolusUnitsPerSecond
                let stepped = min(self.bolusProgrammed, (raw / 0.5).rounded(.down) * 0.5)
                self.bolusEstimated = stepped
                if raw >= self.bolusProgrammed {
                    self.finishBolusTracking(completed: true)
                }
            }
        }
    }

    private func finishBolusTracking(completed: Bool) {
        bolusTimer?.invalidate(); bolusTimer = nil
        bolusRunning = false
        bolusStart = nil
        delivered = bolusEstimated
        let msg = completed
            ? String(format: "大剂量完成（按时间估算 ≈ %.1f U）", bolusEstimated)
            : String(format: "已取消，估算已输注 ≈ %.1f U（以泵屏幕为准）", bolusEstimated)
        lastMessage = msg
        append(msg, out: false)
    }

    func cancelBolus() {
        write(.bolus, rw: .write, payload: PumpCommand.cancelBolus())
        append("取消大剂量", out: false)
        if bolusRunning { finishBolusTracking(completed: false) }
        bolusProgress = nil
    }

    func deliverExtendedBolus(units: Double, minutes: Int) {
        write(.extendedBolus, rw: .write, payload: PumpCommand.extendedBolus(units: units, minutes: minutes))
        append("方波 \(units) U / \(minutes) 分钟", out: false)
    }

    func cancelExtendedBolus() {
        write(.extendedBolus, rw: .write, payload: PumpCommand.cancelExtendedBolus())
        append("取消方波", out: false)
    }

    func setTBR(percent: Int, minutes: Int) {
        write(.tbr, rw: .write, payload: PumpCommand.tbr(percent: percent, minutes: minutes))
        append("TBR \(percent)% / \(minutes) 分钟", out: false)
    }

    func cancelTBR() {
        write(.tbr, rw: .write, payload: PumpCommand.cancelTBR())
        append("取消 TBR", out: false)
    }

    func stopPump() {
        write(.startStop, rw: .write, payload: PumpCommand.startStop(stop: true))
        append("停止输注", out: false)
    }

    func startPump() {
        write(.startStop, rw: .write, payload: PumpCommand.startStop(stop: false))
        append("启动输注", out: false)
    }

    func writeBasalProfile(_ profile: BasalProfile) {
        write(.baseRateTemplate, rw: .write, payload: profile.encode())
        append("写入 48 段基础率模板", out: false)
    }

    /// 读历史大剂量记录：反复发 GHBRq，直到收到 GBRDRp（0xAA02 读）为止
    func fetchHistory() {
        history.removeAll()
        pendingRead = nil
        pendingHistory = true
        write(.history, rw: .read)
        append("读取历史记录…", out: false)
    }

    func fetchLastBolus() {
        guard case .ready = state else { setAlert("未连接，先连接泵"); return }
        pendingRead = .lastBolus; pendingReadCmd = AppFrame.Cmd.lastBolus.rawValue
        write(.lastBolus, rw: .read)
    }
    func fetchBasal() { write(.lastBaseRate, rw: .read) }

    func fetchAlarms() {
        alarmsRaw = ""
        guard case .ready = state else { setAlert("未连接，先连接泵"); return }
        pendingRead = .alarms; pendingReadCmd = AppFrame.Cmd.alarms.rawValue
        write(.alarms, rw: .read)
    }

    func fetchPrime() {
        primeRaw = ""
        guard case .ready = state else { setAlert("未连接，先连接泵"); return }
        pendingRead = .prime; pendingReadCmd = AppFrame.Cmd.prime.rawValue
        write(.prime, rw: .read)
    }

    /// 直接把一串 HEX 写到 FFE9（调试用，不带任何封装）
    func sendRawHex(_ hex: String) -> Bool {
        guard let p = peripheral, let ch = writeChar else { return false }
        guard let bytes = Bytes.fromHex(hex), !bytes.isEmpty else { return false }
        append("RAW → " + Bytes.hex(bytes, separator: " "), out: true)
        let useNoResp = writeWithoutResponse && ch.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = useNoResp ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: ch, type: type)
        if !didLogWriteType {
            didLogWriteType = true
            append("写入方式=\(useNoResp ? "无响应" : "带响应")", out: false)
        }
        return true
    }

    /// 读 FFE9（写特征）——iOS 在访问要求加密的特征时才弹系统配对框
    func readWriteChar() {
        guard let p = peripheral, let ch = writeChar else { setAlert("未连接"); return }
        append("请求读 FFE9（若泵要求加密，这里会弹系统配对框）", out: false)
        p.readValue(for: ch)
    }

    /// 读一帧原始特征值（触发读，常用于强制 iOS 发起配对）
    func readNotifyChar() {
        guard let p = peripheral, let ch = notifyChar else { return }
        append("请求读 FFE4（试探是否需要配对）", out: false)
        p.readValue(for: ch)
    }

    /// 发命令后 6 秒没收到任何回帧 → 给出可操作提示
    private func armNoReplyGuard() {
        noReplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .ready = self.state else { return }
            if let rx = self.lastRxAt, Date().timeIntervalSince(rx) < 6 { return }
            self.lastMessage = "泵无应答（6 秒）：试切帧格式 / 先在系统蓝牙里配对"
            self.append("⏱ 6 秒无回帧：若一直如此，切到另一套帧格式再试；仍未回应说明泵要求系统级配对", out: false)
        }
        noReplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }


    func setAlert(_ text: String) {
        lastMessage = "⚠️ " + text
        append("⚠️ " + text, out: false)
    }

    // MARK: - 收帧

    private func ingest(_ data: [UInt8]) {
        lastRxAt = Date()
        rxBuffer.append(contentsOf: data)
        while rxBuffer.count >= 3 {
            let head = rxBuffer[0]
            // 回帧：0xAA 头，len = 整帧长度，无 serial
            if head == 0xAA {
                let len = Int(rxBuffer[1]) | (Int(rxBuffer[2]) << 8)
                guard len >= 8, len <= 512 else { rxBuffer.removeFirst(); continue }
                guard rxBuffer.count >= len else { return }
                let bytes = Array(rxBuffer[0..<len])
                rxBuffer.removeFirst(len)
                handleReply(bytes)
                continue
            }
            // 下行回显/旧格式：0x55 头
            if head == 0x55 {
                let len = Int(rxBuffer[1]) | (Int(rxBuffer[2]) << 8)
                let minLen = (frameVariant == .official) ? 20 : 23
                guard len >= minLen, len <= 512 else { rxBuffer.removeFirst(); continue }
                guard rxBuffer.count >= len else { return }
                let bytes = Array(rxBuffer[0..<len])
                rxBuffer.removeFirst(len)
                handle(bytes)
                continue
            }
            rxBuffer.removeFirst()
        }
    }

    private func handleReply(_ bytes: [UInt8]) {
        guard let r = ReplyFrame.decode(bytes) else {
            append("⚠️ 回帧解析失败 \(Bytes.hex(bytes, separator: " "))", out: false)
            return
        }
        lastReplyHex = Bytes.hex(r.payload, separator: " ")
        lastReplyCmd = r.rawCmd
        if r.crcOK { lastValidFrameAt = Date() } else { lastMessage = "⚠️ 回帧 CRC 校验失败" }

        switch r.rawCmd {
        case 0xAA00:
            if let s = OfficialStatus.decode(r.payload) {
                status = nil
                officialStatus = s
                lastMessage = String(format: "已读取：电量 %d%% · 余量 %.1fU · 今日 %.1fU",
                                     s.batteryPercent, s.remainingUnits, s.dayTotaled)
            } else {
                lastMessage = "状态帧长度不足（\(r.payload.count)B）"
            }
        case 0xAAAA:
            if r.payload.count >= 2 {
                let raw = Int(r.payload[0]) | (Int(r.payload[1]) << 8)
                let actual = Double(raw) / 10
                delivered = actual
                bolusEstimated = actual
                bolusRunning = false
                lastMessage = String(format: "泵回报：实际输注 %.1f U", actual)
            } else {
                lastMessage = "泵已确认执行"
            }
        case 0xAA55:
            lastMessage = "泵已接受指令"
        case 0xAAA0:
            if r.payload.count >= 2 {
                let raw = Int(r.payload[0]) | (Int(r.payload[1]) << 8)
                let progress = Double(raw) / 10
                bolusProgress = progress
                bolusEstimated = progress
                lastMessage = String(format: "执行中，泵回报已输注 %.1f U", progress)
            } else {
                lastMessage = "执行中…"
            }
        case 0xAA5A:
            lastMessage = "泵拒绝：参数错误"
        case 0xAAA5:
            lastMessage = "泵拒绝：当前状态不允许"
        case 0x0001:
            if let b = LastBolus.decode(r.payload) {
                lastBolus = b
                lastMessage = String(format: "最近大剂量 %.1fU @ %@", b.bolus, b.time.text)
            } else {
                lastMessage = "已收到大剂量记录，解析失败"
            }
        default:
            lastMessage = String(format: "收到回帧 0x%04X（%d 字节）", r.rawCmd, r.payload.count)
        }
    }

    private func handle(_ bytes: [UInt8]) {
        append(Bytes.hex(bytes, separator: " "), out: false)
        guard let frame = AppFrame.decode(bytes, variant: frameVariant) else {
            lastMessage = "帧解析失败"; return
        }
        if !frame.crcOK { lastMessage = "⚠️ CRC 校验失败" }
        lastReplyHex = Bytes.hex(frame.payload, separator: " ")
        lastReplyCmd = frame.rawCmd
        if frame.crcOK { lastValidFrameAt = Date() }

        if let kind = pendingRead, frame.rawCmd == pendingReadCmd {
            pendingRead = nil
            switch kind {
            case .lastBolus:
                lastBolus = LastBolus.decode(frame.payload)
                lastMessage = lastBolus == nil ? "已收到回帧，但解析失败（见原始数据）" : "已读取最近大剂量"
            case .alarms:
                alarmsRaw = lastReplyHex
                lastMessage = "已读取报警数据"
            case .prime:
                primeRaw = lastReplyHex
                lastMessage = "已读取排气数据"
            }
            return
        }

        switch frame.cmd {
        case .fullStatus:
            if let s = PumpStatus.parse(frame.payload) {
                status = s
                if lastMessage.isEmpty { lastMessage = "状态已更新" }
            }
        case .accOK:
            lastMessage = "泵已接受指令"
        case .executing:
            lastMessage = "执行中…"
        case .executed:
            if let info = ExecutedInfo.decode(frame.payload) {
                delivered = info.delivered
                lastMessage = String(format: "已执行，实际输注 %.1f U", info.delivered)
            } else {
                lastMessage = "已执行"
            }
        case .accError:
            lastMessage = "泵拒绝：参数错误"
        case .denied:
            lastMessage = "泵拒绝：当前状态不允许"
        case .history:
            let recs = HistoryRecord.decodeAll(frame.payload)
            history.append(contentsOf: recs)
            if pendingHistory { write(.history, rw: .read) }
        case .historyDone:
            pendingHistory = false
            lastMessage = "历史记录读取完毕（\(history.count) 条）"
        case .lastBolus:
            lastBolus = LastBolus.decode(frame.payload)
            lastMessage = "已读取最近大剂量"
        case .lastBaseRate:
            basalState = BasalState.decode(frame.payload)
            lastMessage = "已读取基础率模板"
        case .alarms:
            alarmsRaw = Bytes.hex(frame.payload, separator: " ")
            lastMessage = "已读取报警数据"
        case .prime:
            primeRaw = Bytes.hex(frame.payload, separator: " ")
            lastMessage = "已读取排气数据"
        default:
            lastMessage = "收到 0x\(String(format: "%04X", frame.rawCmd))"
        }
    }

    /// 导出日志文本（供复制粘贴）
    func exportLog(limit: Int = 100) -> String {
        let batch = log.prefix(limit).reversed()
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var head = "迈世通泵 v\(ver) (build \(build))\n"
        head += "serial=\(frameSerial) variant=\(frameVariant.rawValue) mtu=\(negotiatedMTU)\n"
        head += batch.map { ($0.outbound ? "→ " : "← ") + $0.text }.joined(separator: "\n")
        return head
    }

    private func append(_ s: String, out: Bool) {
        log.insert(LogLine(text: s, outbound: out), at: 0)
        if log.count > 400 { log.removeLast(log.count - 400) }
    }
}

// MARK: - CBCentralManagerDelegate

extension PumpLink: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if case .poweredOff = self.state { self.state = .idle }
                self.autoConnectIfRemembered()
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
            self.rxPackets = 0
            self.rxBuffer.removeAll()
            self.append("已连接，发现服务…", out: false)
            peripheral.discoverServices(PumpLink.serviceRead)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.state = .failed("连接失败：\(error?.localizedDescription ?? "未知错误")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.pollTimer?.invalidate(); self.pollTimer = nil
            self.probeWork?.cancel(); self.noReplyWork?.cancel()
            self.writeChar = nil; self.notifyChar = nil
            self.append("连接已断开 \(error?.localizedDescription ?? "")", out: false)
            self.state = .idle
            if self.autoReconnect {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.autoReconnect, self.state == .idle else { return }
                    self.append("自动重连…", out: false)
                    self.connectLastKnown()
                }
                self.reconnectWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            }
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
            // 完整 dump GATT 树，确认通知/写特征是否和我们假设一致
            for s in peripheral.services ?? [] {
                for c in s.characteristics ?? [] {
                    var p: [String] = []
                    if c.properties.contains(.read) { p.append("read") }
                    if c.properties.contains(.write) { p.append("write") }
                    if c.properties.contains(.writeWithoutResponse) { p.append("noResp") }
                    if c.properties.contains(.notify) { p.append("notify") }
                    if c.properties.contains(.indicate) { p.append("indicate") }
                    self.append("GATT \(s.uuid.uuidString.suffix(8)) / \(c.uuid.uuidString.suffix(8)) [\(p.joined(separator: ","))]", out: false)
                }
            }
            for c in service.characteristics ?? [] {
                if c.uuid == PumpLink.charNotify {
                    self.notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                } else if c.uuid == PumpLink.charWrite {
                    self.writeChar = c
                }
            }
            guard self.writeChar != nil, self.notifyChar != nil, self.state != .ready else { return }
            let props = self.writeChar?.properties ?? []
            self.append("写特征属性：\(props.contains(.write) ? "write " : "")\(props.contains(.writeWithoutResponse) ? "noResp " : "")\(props.contains(.notify) ? "notify " : "")", out: false)
            self.pumpSerial = peripheral.name ?? ""
            self.append("特征就绪，等待通知开启…", out: false)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let e = error {
                self.append("开启通知失败：\(e.localizedDescription)", out: false)
                return
            }
            guard characteristic.isNotifying, self.state != .ready else {
                self.append("通知已开启", out: false)
                return
            }
            self.state = .ready
            let mtu = self.peripheral?.maximumWriteValueLength(for: .withResponse) ?? 0
            self.negotiatedMTU = mtu
            self.append("就绪，serial = \(self.pumpSerial)，上限 \(mtu)B", out: false)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.syncTime()
                self?.requestStatus()
                self?.startPolling()
            }
            // 2 秒仍无回帧 → 重写一次订阅描述符（官方也有同样的重试逻辑）
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.peripheral?.state == .connected else { return }
                if self.rxPackets == 0 {
                    self.append("2 秒无回帧，重写订阅描述符后重发", out: false)
                    if let n = self.notifyChar { self.peripheral?.setNotifyValue(false, for: n) }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if let n = self.notifyChar { self.peripheral?.setNotifyValue(true, for: n) }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.requestStatus()
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            let d = PumpLink.describe(e)
            Task { @MainActor in
                self.lastMessage = "读特征失败：" + d
                self.append("读特征失败：" + d, out: false)
            }
            return
        }
        guard let d = characteristic.value else { return }
        let bytes = [UInt8](d)
        Task { @MainActor in
            self.rxPackets += 1
            self.append("← RAW#\(self.rxPackets) (\(bytes.count)B) \(Bytes.hex(bytes, separator: " "))", out: false)
            self.ingest(bytes)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            let d = PumpLink.describe(e)
            Task { @MainActor in
                self.lastMessage = "写入失败：" + d
                self.append("写入失败：" + d, out: false)
            }
        }
    }

}

// MARK: - 轮询

extension PumpLink {
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestStatus() }
        }
    }
}
