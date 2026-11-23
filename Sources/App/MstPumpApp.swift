import SwiftUI
import UIKit

@main
struct MstPumpApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var link = PumpLink()
    @State private var showSettings = false

    var body: some View {
        TabView {
            PumpTab(link: link, showSettings: $showSettings)
                .tabItem { Label("泵", systemImage: "waveform.path.ecg") }

            BolusTab(link: link)
                .tabItem { Label("打药", systemImage: "syringe") }

            BasalTab(link: link)
                .tabItem { Label("基础率", systemImage: "chart.bar") }

            LogTab(link: link)
                .tabItem { Label("日志", systemImage: "terminal") }
        }
        .sheet(isPresented: $showSettings) { SafetySettingsView() }
    }
}

// MARK: - 泵 / 状态

struct PumpTab: View {
    @ObservedObject var link: PumpLink
    @Binding var showSettings: Bool

    var body: some View {
        NavigationStack {
            List {
                linkSection
                if case .ready = link.state { statusSection }
                Section("整机控制") {
                    Button("校时（同步手机时间）") { link.syncTime() }
                    Button("启动输注") { link.startPump() }
                    Button("停止输注", role: .destructive) { link.stopPump() }
                }
            }
            .navigationTitle("迈世通泵")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("安全") { showSettings = true }
                }
            }
        }
    }

    private var linkSection: some View {
        Section("连接") {
            switch link.state {
            case .ready:
                HStack {
                    Label(link.pumpSerial.isEmpty ? "已连接" : link.pumpSerial,
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("断开") { link.disconnect() }.buttonStyle(.bordered)
                }
            case .scanning:
                HStack {
                    Text("扫描中…").foregroundStyle(.secondary)
                    Spacer(); ProgressView()
                    Button("停止") { link.stopScan() }
                }
                ForEach(link.devices) { d in
                    Button {
                        link.connect(d)
                    } label: {
                        HStack {
                            Text(d.name)
                            Spacer()
                            Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            case .connecting(let name):
                HStack { Text("正在连接 \(name)…"); Spacer(); ProgressView() }
            case .poweredOff:
                Text("蓝牙未开启").foregroundStyle(.red)
            case .failed(let msg):
                Text(msg).foregroundStyle(.red)
                Button("重新扫描") { link.startScan() }
            case .idle:
                Button("扫描泵") { link.startScan() }.buttonStyle(.borderedProminent)
            }
            if !link.lastMessage.isEmpty {
                Text(link.lastMessage).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var statusSection: some View {
        Section("泵状态") {
            if let s = link.status {
                row("电量", "\(s.battery)%")
                row("药量剩余", String(format: "%.1f U", s.boxVolume))
                row("今日总量", String(format: "%.1f U", s.dayTotaled))
                row("基础分段", "\(s.baseSegs) 段")
                row("基础率模式", s.tbaseMode == 0 ? "普通" : "分段")
                row("当前基础率", link.basalState.map { String(format: "%.2f U/h", $0.activeRate) } ?? "—")
                row("单次上限", "\(s.maxBolus / 10) U")
                row("日上限", "\(s.maxDaily / 10) U")
                row("错误标志", s.errflag == 0 ? "无" : "0x\(String(format: "%02X", s.errflag))")
                if let d = link.delivered {
                    row("上次实际输注", String(format: "%.1f U", d))
                }
            } else {
                Text("等待状态…").foregroundStyle(.secondary)
            }
            Button("立即刷新") { link.requestStatus() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}

// MARK: - 打药

struct BolusTab: View {
    @ObservedObject var link: PumpLink

    @AppStorage("safety.maxBolus") private var maxBolus: Double = 10
    @AppStorage("safety.maxTbrPercent") private var maxTbr: Int = 200

    @State private var bolusText = ""
    @State private var extUnitsText = "1"
    @State private var extMinutes = 60
    @State private var confirmBolus: Double?
    @State private var confirmExt: (Double, Int)?

    var body: some View {
        NavigationStack {
            List {
                Section("常规大剂量") {
                    HStack {
                        TextField("单位 U（例 2.5）", text: $bolusText).keyboardType(.decimalPad)
                        Text("U").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("安全上限 \(String(format: "%.1f", maxBolus)) U")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("输注") {
                            guard let u = Double(bolusText), u > 0 else { return }
                            guard u <= maxBolus else {
                                link.setAlert("\(u) U 超过安全上限 \(maxBolus) U"); return
                            }
                            confirmBolus = u
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("立即取消正在输注的大剂量", role: .destructive) { link.cancelBolus() }
                    if let d = link.delivered {
                        Text(String(format: "泵回报最近一次实际输注：%.1f U", d))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("方波（延长）大剂量") {
                    HStack {
                        Text("总量"); Spacer()
                        TextField("U", text: $extUnitsText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                    Stepper("延长时间 \(extMinutes) 分钟", value: $extMinutes, in: 15...480, step: 15)
                    HStack {
                        Button("开始方波") {
                            guard let u = Double(extUnitsText), u > 0, u <= maxBolus else {
                                link.setAlert("方波总量不合法或超过上限"); return
                            }
                            confirmExt = (u, extMinutes)
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("取消方波", role: .destructive) { link.cancelExtendedBolus() }
                    }
                }

                Section("临时基础率 TBR") {
                    Stepper("比例 \(tbrPercent)%", value: $tbrPercent, in: 0...maxTbr, step: 10)
                    Stepper("时长 \(tbrMinutes) 分钟", value: $tbrMinutes, in: 15...360, step: 15)
                    HStack {
                        Button("设置 TBR") { link.setTBR(percent: tbrPercent, minutes: tbrMinutes) }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("取消 TBR") { link.cancelTBR() }
                    }
                    Text("泵按 15 分钟步进、10% 步进接收，非整值会被截断。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("打药")
            .alert("确认大剂量", isPresented: Binding(
                get: { confirmBolus != nil }, set: { if !$0 { confirmBolus = nil } })) {
                Button("取消", role: .cancel) { confirmBolus = nil }
                Button("确认输注", role: .destructive) {
                    if let u = confirmBolus { link.deliverBolus(u) }
                    confirmBolus = nil
                }
            } message: {
                Text("即将输注 \(String(format: "%.1f", confirmBolus ?? 0)) U，请核对剂量。")
            }
            .alert("确认方波", isPresented: Binding(
                get: { confirmExt != nil }, set: { if !$0 { confirmExt = nil } })) {
                Button("取消", role: .cancel) { confirmExt = nil }
                Button("确认", role: .destructive) {
                    if let (u, m) = confirmExt { link.deliverExtendedBolus(units: u, minutes: m) }
                    confirmExt = nil
                }
            } message: {
                Text("方波 \(String(format: "%.1f", confirmExt?.0 ?? 0)) U / \(confirmExt?.1 ?? 0) 分钟")
            }
        }
    }

    @State private var tbrPercent = 100
    @State private var tbrMinutes = 30
}

// MARK: - 基础率

struct BasalTab: View {
    @ObservedObject var link: PumpLink
    @State private var uniformRate = ""
    @State private var confirmWrite = false

    var body: some View {
        NavigationStack {
            List {
                Section("泵内当前模板") {
                    if let b = link.basalState {
                        Text("读取时间 \(b.time.text)").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "加权当前基础率 %.2f U/h", b.activeRate))
                        Text(String(format: "模板日总量 %.2f U", b.profile.totalDaily))
                            .font(.footnote).foregroundStyle(.secondary)
                        NavigationLink("查看 48 段明细") {
                            BasalDetailList(profile: b.profile)
                        }
                    } else {
                        Text("尚未读取").foregroundStyle(.secondary)
                    }
                    Button("从泵读取") { link.fetchBasal() }
                }

                Section("写入新模板") {
                    HStack {
                        TextField("统一基础率 U/h（例 1.2）", text: $uniformRate)
                            .keyboardType(.decimalPad)
                        Text("U/h").foregroundStyle(.secondary)
                    }
                    Button("按该值写满 48 段") {
                        guard let r = Double(uniformRate), r >= 0, r <= 5 else {
                            link.setAlert("基础率需在 0–5 U/h 之间"); return
                        }
                        confirmWrite = true
                    }
                    .buttonStyle(.borderedProminent)
                    Text("每段 30 分钟。写入后请立刻在泵屏幕上核对，并重新「从泵读取」确认生效。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("基础率")
            .alert("写入基础率模板？", isPresented: $confirmWrite) {
                Button("取消", role: .cancel) {}
                Button("写入", role: .destructive) {
                    let r = Double(uniformRate) ?? 0
                    link.writeBasalProfile(BasalProfile(segments: Array(repeating: r, count: 48)))
                }
            } message: {
                Text("将把 48 段全部写成 \(uniformRate) U/h 并下发给泵。")
            }
        }
    }
}

struct BasalDetailList: View {
    let profile: BasalProfile
    var body: some View {
        List {
            ForEach(0..<48, id: \.self) { i in
                HStack {
                    Text(String(format: "%02d:%02d", i / 2, (i % 2) * 30))
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(String(format: "%.2f U/h", profile.segments[i]).replacingOccurrences(of: ".", with: "."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("48 段明细")
    }
}

// MARK: - 日志

struct LogTab: View {
    @ObservedObject var link: PumpLink
    @State private var onlyOutgoing = false
    @State private var rawHex = ""
    @State private var serialDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section("帧格式") {
                    Picker("协议", selection: Binding(
                        get: { link.frameVariant },
                        set: { link.frameVariant = $0 })) {
                        ForEach(AppFrame.Variant.allCases) { v in
                            Text(v.title).tag(v)
                        }
                    }
                    Text("官方格式：无 msgId 尾、serial 取名字分隔符后的段；AAPS 格式：多 3 字节。连不上或命令没反应就先切换这里。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("连接后自动探测协议", isOn: Binding(
                        get: { link.autoProbe },
                        set: { link.autoProbe = $0 }))
                    Text("开启时：先用官方帧读状态，3.5 秒没回帧就自动改发 AAPS 帧；哪套有应答就固定用哪套。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("当前发送 serial：\(link.frameVariant == .legacy ? "01" + PumpSerial.from(deviceName: link.pumpSerial) : PumpSerial.from(deviceName: link.pumpSerial))")
                        .font(.system(.caption2, design: .monospaced))
                    if let rx = link.lastRxAt {
                        Text("最后一次收到回帧：\(rx.formatted(date: .omitted, time: .standard)) · MTU \(link.negotiatedMTU)B")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section("链路诊断") {
                    if !link.lastReplyHex.isEmpty {
                        Text("最近回帧 0x\(String(format: "%04X", link.lastReplyCmd))：\(link.lastReplyHex)")
                            .font(.system(.caption2, design: .monospaced)).lineLimit(3)
                    }
                    HStack {
                        Text("serial").font(.caption).foregroundStyle(.secondary)
                        TextField("留空=用蓝牙名（12 字节内）", text: $serialDraft)
                            .font(.system(.caption, design: .monospaced))
                            .autocapitalization(.allCharacters)
                            .onSubmit { link.serialOverride = serialDraft }
                    }
                    Button("应用 serial") { link.serialOverride = serialDraft }
                    Toggle("写入不带响应（写不通时可切换试）", isOn: Binding(
                        get: { link.writeWithoutResponse },
                        set: { link.writeWithoutResponse = $0 }))
                    Button("读一次 FFE4（试探是否需要配对）") { link.readNotifyChar() }
                    Button("读一次 FFE9（触发系统配对弹窗）") { link.readWriteChar() }
                    Text("写入报 insufficient authentication 时，先去 iOS 设置→蓝牙 里配对泵，再回来重连。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("裸发 HEX") {
                    TextField("例如 55001700A1...", text: $rawHex)
                        .font(.system(.caption, design: .monospaced))
                        .autocapitalization(.allCharacters)
                    Button("直接写 FFE9") {
                        if !link.sendRawHex(rawHex) { link.setAlert("未连接或 HEX 非法") }
                    }
                }
                Section("日志") {
                    Toggle("只看发出的帧", isOn: $onlyOutgoing)
                    HStack {
                        Button("复制全部日志") {
                            UIPasteboard.general.string = link.exportLog(limit: 400)
                            link.setAlert("已复制，可直接粘贴发我")
                        }
                        Spacer()
                        Button("复制最近 30 条") {
                            UIPasteboard.general.string = link.exportLog(limit: 30)
                            link.setAlert("已复制 30 条")
                        }
                    }
                    .font(.footnote)
                    ForEach(onlyOutgoing ? link.log.filter { $0.outbound } : link.log) { l in
                        HStack(alignment: .top, spacing: 8) {
                            Text(l.outbound ? "→" : "←")
                                .foregroundStyle(l.outbound ? .blue : .green)
                                .font(.system(.caption, design: .monospaced))
                            Text(l.text).font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("通信 / 诊断")
            .onAppear { serialDraft = link.serialOverride }
        }
    }
}

// MARK: - 安全设置

struct SafetySettingsView: View {
    @AppStorage("safety.maxBolus") private var maxBolus: Double = 10
    @AppStorage("safety.maxTbrPercent") private var maxTbr: Int = 200
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("硬性上限") {
                    Stepper("单次大剂量 ≤ \(String(format: "%.1f", maxBolus)) U",
                            value: $maxBolus, in: 0.5...30, step: 0.5)
                    Stepper("TBR 比例 ≤ \(maxTbr)%", value: $maxTbr, in: 50...250, step: 10)
                }
                Section {
                    Text("这些上限只在本 App 内生效，用于防误操作；泵自身的参数限制仍需在泵上确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("安全设置")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
