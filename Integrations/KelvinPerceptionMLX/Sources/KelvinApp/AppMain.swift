import SwiftUI
import AppKit
import KelvinCore

@main
struct KelvinApp: App {
    /// Held at App level so both the window and the File menu act on one state.
    @StateObject private var appState = AppState()

    init() {
        // Become a regular foreground app even when launched unbundled (`swift run`): otherwise
        // the process runs as a background/accessory role — its window never shows, and macOS
        // grants it a background/accessory role rather than a foreground one, so no window shows.
        // (An earlier version of this comment blamed jetsam memory limits for the bundled app's
        // death on first model load. That was wrong — it was MLX failing to locate
        // default.metallib; see scripts/package-app.sh.)
        NSApplication.shared.setActivationPolicy(.regular)
        // Dock icon from embedded bytes (works under `swift run` too; no Bundle.module).
        if let data = Data(base64Encoded: AppIconData.base64), let icon = NSImage(data: data) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 940, minHeight: 660)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        // Hidden title bar so the darkroom UI runs edge to edge — the window is the instrument.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // There was no File ▸ Open and no ⌘O at all — the only way in was the empty state's
            // button, so with a photo already open Kelvin could not be given another one. ⌘O is
            // the first thing anyone reaches for.
            CommandGroup(replacing: .newItem) {
                Button("Open Photo or Folder…") { appState.chooseAndOpen() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Close Photo") { appState.closeCurrentPhoto() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(appState.imageURL == nil)
            }
        }
    }
}
