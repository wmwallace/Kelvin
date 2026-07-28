import SwiftUI
import AppKit
import KelvinCore
import Sparkle

/// Photographs handed to Kelvin by the system — "Open With", a double-click once Kelvin is the
/// default, or a drop on the Dock icon.
///
/// **A queue rather than a direct call, because the request usually arrives first.** Launch
/// Services delivers the open event during startup, and `appState` is a `@StateObject` that does
/// not exist until SwiftUI first evaluates the scene's body. Opening Kelvin BY double-clicking a
/// RAW — which is the whole point of being a handler — therefore hits a nil state every time,
/// while opening a second photo into an already-running app works. The failure only shows up in
/// the case the feature exists for.
@MainActor
final class OpenRequests {
    static let shared = OpenRequests()
    private var pending: [URL] = []
    private weak var state: AppState?

    /// Called once the window exists. Drains anything that arrived before it did.
    func attach(_ state: AppState) {
        self.state = state
        let queued = pending
        pending = []
        queued.forEach(deliver)
    }

    /// One photograph, or the first of a selection: Kelvin edits one frame at a time and lists the
    /// rest of the folder around it, so opening five files and opening one of them are the same
    /// request. A folder arrives here too and `open(_:)` already knows what to do with it.
    func receive(_ urls: [URL]) {
        guard let first = urls.first else { return }
        state == nil ? pending.append(first) : deliver(first)
    }

    private func deliver(_ url: URL) {
        guard let state else { return }
        Task { await state.open(url) }
    }
}

/// The only reason this exists. SwiftUI's `onOpenURL` is for custom schemes; a file handed over by
/// Launch Services arrives through the `NSApplicationDelegate`.
@MainActor
final class DocumentOpenDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, open urls: [URL]) {
        OpenRequests.shared.receive(urls)
    }
}

@main
struct KelvinApp: App {
    /// Held at App level so both the window and the File menu act on one state.
    @StateObject private var appState = AppState()

    @NSApplicationDelegateAdaptor(DocumentOpenDelegate.self) private var openDelegate

    /// Sparkle, but only where Sparkle can mean anything: a bundle whose Info.plist carries
    /// `SUFeedURL` (scripts/package-app.sh writes it from `Branding.appcastURL`). A `swift run`
    /// dev build has no plist, so it gets no updater and no menu item rather than a broken one.
    ///
    /// Checks are AUTOMATIC by default, set in the Info.plist the packaging script writes, and
    /// both switches live in Settings ▸ General (see `UpdateSettings`). This reversed the original
    /// consent-first stance deliberately: the update check is the one outbound request a release
    /// makes, and an alpha that only updates the users who said yes to a dialog leaves known-bad
    /// builds in the field. SECURITY.md and the README say so in the same words.
    private let updaterController: SPUStandardUpdaterController? =
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            ? SPUStandardUpdaterController(startingUpdater: true,
                                           updaterDelegate: nil, userDriverDelegate: nil)
            : nil

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
                .onAppear {
                    // Before anything else that can take time: a photograph double-clicked in
                    // Finder is already waiting, and it should open ahead of the model warming.
                    OpenRequests.shared.attach(appState)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    // Off unless KELVIN_TRACE_HITCHES is set. See Diagnostics.swift.
                    HitchMonitor.shared.start()
                    // Load the model while the window sits on the empty state, rather than charging
                    // fifteen seconds to whichever photograph is opened first. Background priority:
                    // this must never compete with decoding a photo somebody just dropped.
                    Task(priority: .background) { await appState.warmPerception() }
                }
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
            if let updater = updaterController?.updater {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
            }
            // The Help menu was empty, which is where people look before they look anywhere else.
            CommandGroup(replacing: .help) {
                Button("\(Branding.displayName) on GitHub") { open(Branding.repositoryURL) }
                Button("Report a Bug…") { NSWorkspace.shared.open(AppInfo.bugReportURL) }
            }
        }

        // ⌘, did nothing before this. Two preferences were already being remembered between
        // launches — whether opening a photo lists its folder, and whether an export carries the
        // photograph's location — and both were reachable only from inside a file panel, which is
        // to say only while you were busy doing something else.
        Settings {
            SettingsView(appState: appState, updater: updaterController?.updater)
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
