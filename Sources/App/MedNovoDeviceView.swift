import SwiftUI

/// 设备面板：把泵的实体示意图当"外壳"，屏幕区域叠真实状态
/// 图片为自绘图层（透明背景 + 机身/屏幕/按键分层合成），比例 600×970
struct MedNovoDeviceView: View {
    @ObservedObject var link: PumpLink
    var width: CGFloat = 220

    /// 屏幕在图片里的归一化矩形（由绘制脚本导出，勿手调）
    private let screen = CGRect(x: 0.10, y: 0.2474, width: 0.80, height: 0.7010)
    private let imageAspect: CGFloat = 970.0 / 600.0

    private var height: CGFloat { width * imageAspect }
    private var connected: Bool { if case .ready = link.state { return true }; return false }

    private var clockText: String {
        guard let t = link.officialStatus?.time else { return "—:—" }
        return String(format: "%02d:%02d", t.hour, t.minute)
    }

    var body: some View {
        ZStack {
            Image("MedNovoDevice")
                .interpolation(.high)
                .resizable()
                .frame(width: width, height: height)

            screenContent
                .frame(width: width * screen.width, height: height * screen.height)
                .offset(x: width * (screen.midX - 0.5),
                        y: height * (screen.midY - 0.5))
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("迈世通泵状态面板")
    }

    private var screenContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(clockText)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: connected ? "wave.3.right" : "wave.3.right.slash")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(ink)

            Spacer(minLength: 4)

            if let s = link.officialStatus {
                big(String(format: "%.1f", s.remainingUnits), unit: "U", caption: "药量剩余")
                Spacer(minLength: 4)
                HStack(spacing: 12) {
                    metric("电量", "\(s.batteryPercent)%")
                    metric("今日", String(format: "%.1fU", s.dayTotaled))
                }
            } else {
                Text(connected ? "读取中…" : "未连接")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.75))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var ink: Color { Color(red: 0.06, green: 0.20, blue: 0.30) }

    private func big(_ value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(unit).font(.system(size: 11, weight: .semibold))
            }
            Text(caption).font(.system(size: 9, weight: .medium)).opacity(0.7)
        }
        .foregroundStyle(ink)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9, weight: .medium)).opacity(0.7)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(ink)
    }
}
