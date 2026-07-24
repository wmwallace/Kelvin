import SwiftUI
import KelvinCore

@main
struct KelvinApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 940, minHeight: 660)
        }
        // Hidden title bar so the darkroom UI runs edge to edge — the window is the instrument.
        .windowStyle(.hiddenTitleBar)
    }
}
