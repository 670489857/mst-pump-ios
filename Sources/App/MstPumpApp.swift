import SwiftUI
import PumpKit

@main
struct MstPumpApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "drop.fill")
                .font(.system(size: 56))
                .foregroundColor(.blue)
            Text("迈世通胰岛素泵")
                .font(.title2).bold()
            Text("驱动内核 v\(PumpKitInfo.version) 已加载")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("蓝牙扫描与配对将在下一版接入")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
