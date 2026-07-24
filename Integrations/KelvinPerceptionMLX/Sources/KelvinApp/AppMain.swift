import SwiftUI
import AppKit
import KelvinCore

@main
struct KelvinApp: App {
    init() {
        // Become a regular foreground app even when launched unbundled (`swift run`): otherwise
        // the process runs as a background/accessory role — its window never shows, and macOS
        // grants it tight (jetsam-prone) memory limits that the 2.9 GB model load can trip.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 940, minHeight: 660)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        // Hidden title bar so the darkroom UI runs edge to edge — the window is the instrument.
        .windowStyle(.hiddenTitleBar)
    }
}
