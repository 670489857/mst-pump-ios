import SwiftUI

/// 设备示意图（纯静态插图，不叠加实时数据）
/// 图片为自绘图层：透明背景 + 机身/屏幕/按键分层合成，比例 600×970
struct MedNovoDeviceView: View {
    var width: CGFloat = 220

    var body: some View {
        Image("MedNovoDevice")
            .interpolation(.high)
            .resizable()
            .aspectRatio(600.0 / 970.0, contentMode: .fit)
            .frame(width: width)
            .accessibilityLabel("迈世通胰岛素泵")
    }
}
