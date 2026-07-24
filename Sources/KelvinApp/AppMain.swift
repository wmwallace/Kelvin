import SwiftUI
import KelvinCore

@main
struct KelvinApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
