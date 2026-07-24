import SwiftUI
import AppKit
import KelvinCore

@main
struct KelvinApp: App {
    init() {
        // Set the Dock/app icon at runtime so it shows even when launched via `swift run`
        // (no .app bundle). The packaged .app also carries the .icns via Info.plist.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 940, minHeight: 660)
        }
        // Hidden title bar so the darkroom UI runs edge to edge — the window is the instrument.
        .windowStyle(.hiddenTitleBar)
    }
}
