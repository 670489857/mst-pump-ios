import SwiftUI

/// 设备示意图（纯静态插图，不叠加实时数据）
/// 产品实拍图去背后直贴，比例 1433×763（透明底，与 App 背景融合）
struct MedNovoDeviceView: View {
    var width: CGFloat = 272

    var body: some View {
        Image("MedNovoDevice")
            .interpolation(.high)
            .resizable()
            .aspectRatio(1433.0 / 763.0, contentMode: .fit)
            .frame(width: width)
            .accessibilityLabel("迈世通胰岛素泵")
    }
}
