import SwiftUI
import AppKit
import KelvinCore
import Sparkle
import os

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

    /// The state the window is showing, for the one other delegate callback that needs it: quit.
    var attachedState: AppState? { state }

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

/// Two jobs. Files: SwiftUI's `onOpenURL` is for custom schemes, and a file handed over by Launch
/// Services arrives through the `NSApplicationDelegate`. And quitting, which turned out to need
/// more care than "let AppKit do it" — see `applicationShouldTerminate`.
@MainActor
final class DocumentOpenDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "Lifecycle")
    private var quitting = false

    func application(_ sender: NSApplication, open urls: [URL]) {
        OpenRequests.shared.receive(urls)
    }

    /// Kelvin is one window. Closing it is how people quit, and an app that stays in the Dock
    /// with nothing to show was read as "it says it's running but it isn't" — which, on the day
    /// that was investigated, it also literally was (see `Offload`). With the window gone there
    /// is nothing left to keep the process for.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quit in order, rather than on the spot.
    ///
    /// `NSApplication.terminate` calls `exit()`, and `exit()` runs every C++ static destructor in
    /// the process — MLX's among them — while the other threads are still running. A ⌘Q during a
    /// scene read therefore crashed, reliably: the generation thread dereferenced an MLX global
    /// that the main thread had just destroyed (crash report of 21 August 2026, `CustomKernel::
    /// eval_gpu` under `__cxa_finalize_ranges`). The fix is to take the model back first, wait for
    /// it to let go, and only then let AppKit exit.
    ///
    /// Bounded, twice over. `prepareToQuit` waits two seconds at most; and if the model has not
    /// stopped by then — or if the reply never comes because the thing that would deliver it is
    /// itself wedged — the process leaves through `_exit`, which skips the destructors that would
    /// have crashed it. Either way ⌘Q ends the process, without a crash report.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, let state = OpenRequests.shared.attachedState else { return .terminateNow }
        quitting = true
        Self.log.notice("quit requested")
        // Cancel SYNCHRONOUSLY, here, on the main thread — not inside the Task below. AppKit
        // answers `.terminateLater` by spinning a nested run loop inside this very call, and if
        // the quit was asked for from within a main-actor task (a script, a test driver, anything
        // that calls `terminate` from Swift concurrency) that nested loop cannot run another
        // main-actor job: the actor is occupied by the caller. A cancellation that lived in the
        // Task would then never happen. Found by exactly that — the drag-stress harness hung in
        // `_shouldTerminate` with nothing cancelled and nothing replying.
        state.cancelForQuit()
        // The escape hatch is on a GLOBAL queue for the same reason: the main queue is the main
        // actor, and in that nested-loop case it is not draining. `_exit` is safe from any thread
        // and it must be reachable even when the pool — the thing `Offload` protects — has been
        // exhausted after all.
        let hatch = DispatchWorkItem {
            Self.log.fault("quit did not complete in time — leaving through _exit")
            _exit(0)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3, execute: hatch)
        Task { @MainActor in
            let clean = await state.awaitQuiescenceForQuit()
            hatch.cancel()
            if clean {
                Self.log.notice("quit: model and GPU lanes idle, terminating")
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                Self.log.fault("quit: the model or a render was still busy after the grace period — leaving through _exit")
                _exit(0)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.log.notice("terminating")
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
        // Dock icon from embedded bytes (works under `swift run` too; no Bundle.module) — badged
        // with an amber corner when this is a working-tree build rather than the installed app, so
        // two Kelvins in the Dock can be told apart. See BuildIdentity.
        if let icon = BuildIdentity.applicationIcon() {
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
                    // The canary for an exhausted cooperative pool. Always on; see Offload.swift.
                    PoolWatchdog.start()
                    Logger(subsystem: Branding.bundleIdentifier, category: "Lifecycle")
                        .notice("window up — \(BuildIdentity.isDevelopmentBuild ? "development" : "installed", privacy: .public) build")
                    // Off unless KELVIN_TRACE_HITCHES is set. See Diagnostics.swift.
                    HitchMonitor.shared.start()
                    // Load the model while the window sits on the empty state, rather than charging
                    // fifteen seconds to whichever photograph is opened first. Background priority:
                    // this must never compete with decoding a photo somebody just dropped.
                    Task(priority: .background) { await appState.warmPerception() }
                    // Keep the thumbnail/header cache inside its budget. At launch and nowhere else:
                    // it walks a directory listing, so putting it on the path that READS an entry
                    // would make a large cache slow down the thing it exists to speed up.
                    Task.detached(priority: .background) { MediaCache.shared.trim() }
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
