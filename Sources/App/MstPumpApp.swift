import SwiftUI
import PumpKit

@main
struct MstPumpApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var link = PumpLink()

    @AppStorage("safety.maxBolus") private var maxBolusLimit: Double = 10
    @AppStorage("safety.maxTbrPercent") private var maxTbrPercent: Int = 200

    @State private var bolusText = ""
    @State private var tbrPercent = 100
    @State private var tbrMinutes = 30

    @State private var confirmBolus: Double?
    @State private var confirmStop = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                linkSection
                if case .ready = link.state {
                    statusSection
                    bolusSection
                    tbrSection
                    controlSection
                }
                logSection
            }
            .navigationTitle("迈世通泵")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("安全设置") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                SafetySettingsView(maxBolus: $maxBolusLimit, maxTbr: $maxTbrPercent)
            }
        }
        .alert("确认打药", isPresented: Binding(
            get: { confirmBolus != nil },
            set: { if !$0 { confirmBolus = nil } }
        )) {
            Button("取消", role: .cancel) { confirmBolus = nil }
            Button("确认输注", role: .destructive) {
                if let u = confirmBolus { link.deliverBolus(u) }
                confirmBolus = nil
            }
        } message: {
            Text("即将输注 \(String(format: "%.1f", confirmBolus ?? 0)) U 大剂量，请确认剂量无误。")
        }
        .alert("停止输注？", isPresented: $confirmStop) {
            Button("取消", role: .cancel) {}
            Button("停止", role: .destructive) { link.stopPump() }
        } message: {
            Text("将立即停止泵的输注，基础率也会暂停。")
        }
    }

    // MARK: - 连接

    private var linkSection: some View {
        Section("连接") {
            switch link.state {
            case .ready:
                HStack {
                    Label(link.pumpSerial.isEmpty ? "已连接" : link.pumpSerial, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("断开") { link.disconnect() }.buttonStyle(.bordered)
                }
            case .scanning:
                HStack {
                    Text("扫描中…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                    Button("停止") { link.stopScan() }
                }
                ForEach(link.devices) { d in
                    Button {
                        link.connect(d)
                    } label: {
                        HStack {
                            Text(d.name)
                            Spacer()
                            Text("\(d.rssi) dBm").foregroundStyle(.secondary).font(.caption)
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

    // MARK: - 状态

    private var statusSection: some View {
        Section("泵状态") {
            if let s = link.status {
                row("电量", "\(s.battery)%")
                row("药量剩余", String(format: "%.1f U", s.boxVolume))
                row("今日总量", String(format: "%.1f U", s.dayTotaled))
                row("基础分段数", "\(s.baseSegs)")
                row("基础率模式", "\(s.tbaseMode)")
                row("单次最大", "\(s.maxBolus)")
                row("日最大", "\(s.maxDaily)")
                row("错误标志", s.errflag == 0 ? "无" : "0x\(String(format: "%02X", s.errflag))")
            } else {
                Text("等待状态…").foregroundStyle(.secondary)
            }
            Button("立即刷新") { link.requestStatus() }
        }
    }

    // MARK: - 大剂量

    private var bolusSection: some View {
        Section("大剂量") {
            HStack {
                TextField("单位 U（例 2.5）", text: $bolusText)
                    .keyboardType(.decimalPad)
                Text("U").foregroundStyle(.secondary)
            }
            HStack {
                Text("单次上限 \(String(format: "%.1f", maxBolusLimit)) U")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("输注") {
                    guard let u = Double(bolusText), u > 0 else { return }
                    guard u <= maxBolusLimit else {
                        link.setAlert("剂量 \(u) U 超过安全上限")
                        return
                    }
                    confirmBolus = u
                }
                .buttonStyle(.borderedProminent)
            }
            Button("立即取消正在输注的大剂量", role: .destructive) { link.cancelBolus() }
        }
    }

    // MARK: - TBR

    private var tbrSection: some View {
        Section("临时基础率") {
            Stepper("比例 \(tbrPercent)%", value: $tbrPercent, in: 0...maxTbrPercent, step: 10)
            Stepper("时长 \(tbrMinutes) 分钟", value: $tbrMinutes, in: 15...360, step: 15)
            HStack {
                Button("设置 TBR") { link.setTBR(percent: tbrPercent, minutes: tbrMinutes) }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("取消 TBR") { link.cancelTBR() }
            }
        }
    }

    // MARK: - 控制

    private var controlSection: some View {
        Section("整机控制") {
            Button("校时（同步手机时间）") { link.syncTime() }
            Button("启动输注") { link.startPump() }
            Button("停止输注", role: .destructive) { confirmStop = true }
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section("通信日志") {
            ForEach(Array(link.log.prefix(40)), id: \.self) { line in
                Text(line).font(.system(.caption2, design: .monospaced))
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}

struct SafetySettingsView: View {
    @Binding var maxBolus: Double
    @Binding var maxTbr: Int
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
                    Text("这些上限只在本 App 内生效，用于防止误操作；泵本身的参数限制仍需在泵上确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("安全设置")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
