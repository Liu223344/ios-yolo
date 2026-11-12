import SwiftUI

@main
struct YOLOApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView().tabItem { Label("本机检测", systemImage: "viewfinder") }
                LANCameraView().tabItem { Label("传到 Mac", systemImage: "desktopcomputer") }
            }
                .preferredColorScheme(.dark)
        }
    }
}
