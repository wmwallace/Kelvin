import SwiftUI
import AppKit
import KelvinCore
import KelvinPerceptionMLX
import Sparkle

/// Settings — ⌘, — which the app did not have.
///
/// Two preferences already existed with nowhere to live: whether opening one photograph lists the
/// rest of its folder, and whether an export carries the photograph's location. Both were reachable
/// only from inside a file panel, which means a decision about how you work was only visible at the
/// moment you were busy doing something else. Anything that is remembered between launches belongs
/// somewhere you can find it without starting a task first.
///
/// The other half of this window is the part that has to be true rather than merely present: what
/// the app is, what it runs on, where your edits are kept, and what it is licensed under. An AGPL
/// application should be able to answer "where is the source" from inside itself.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    /// Nil in a build from source, which has no feed URL and therefore no updater. See UpdateSettings.
    var updater: SPUUpdater?

    var body: some View {
        TabView {
            GeneralSettings(appState: appState, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
            PerceptionSettings()
                .tabItem { Label("Perception", systemImage: "eye") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Sized rather than resizable: a settings window that opens at some remembered size is one
        // more thing to get wrong, and there is not enough here to need scrolling.
        .frame(width: 520, height: 380)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var appState: AppState
    var updater: SPUUpdater?

    var body: some View {
        Form {
            Section {
                Toggle("Include the rest of the folder when opening a photo",
                       isOn: $appState.includeFolderOnOpen)
                Text(appState.includeFolderOnOpen
                     ? "The other photos are listed in the filmstrip. Nothing is read from them until the strip is open."
                     : "Only the photo you choose — no filmstrip, no arrow keys, and no way to apply a look to the shoot.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Opening")
            }

            Section {
                Picker("File names", selection: $appState.exportNamingId) {
                    ForEach(ExportNaming.Scheme.allCases, id: \.rawValue) {
                        Text($0.label).tag($0.rawValue)
                    }
                }
                Text(ExportNaming.Scheme(rawValue: appState.exportNamingId)?.example ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                if appState.exportNamingId == ExportNaming.Scheme.descriptive.rawValue {
                    // Said once, here, rather than discovered later on a file already sent to a
                    // client: these words come from a model reading the photograph, and models are
                    // wrong sometimes.
                    Text("Descriptive names come from the scene reading, so they can occasionally be wrong — and a filename is hard to take back.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Remove location and camera serial when exporting",
                       isOn: $appState.stripLocationOnExport)
                Text(appState.stripLocationOnExport
                     ? "Camera, lens, date and exposure still travel with the file."
                     : "Exports carry everything the original recorded, including where the photo was taken.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Exporting")
            }

            UpdateSettings(updater: updater)
        }
        .formStyle(.grouped)
    }
}

/// The two update switches, and the only place the automatic default can be turned off.
///
/// Kelvin keeps itself up to date unless told not to. That is a deliberate reversal of where this
/// started — Sparkle asking permission on first launch, defaulting to nothing — because a pre-alpha
/// that only reaches the users who said yes to a dialog is a pre-alpha whose fixes mostly do not
/// arrive. The cost is one outbound request the app would otherwise not make, so it is stated here
/// rather than buried: the section says what is sent, in the window, next to the switch that stops
/// it.
///
/// Sparkle owns the values. Reading them into `@State` on appear and writing back on change keeps
/// the checkboxes honest even when something else changes them — Sparkle's own reminder sheets can.
private struct UpdateSettings: View {
    let updater: SPUUpdater?
    @State private var checksAutomatically = false
    @State private var installsAutomatically = false

    var body: some View {
        Section {
            if updater == nil {
                // A build from source has no feed and no updater. Saying so is better than showing
                // two switches that would silently do nothing.
                Text("This build has no updater. Releases check \(Branding.appcastURL); a copy built from source updates when you rebuild it.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Check for updates automatically", isOn: $checksAutomatically)
                    .onChange(of: checksAutomatically) {
                        updater?.automaticallyChecksForUpdates = checksAutomatically
                        // Installing without checking is not a state that means anything.
                        if !checksAutomatically { installsAutomatically = false }
                    }
                Toggle("Download and install them automatically", isOn: $installsAutomatically)
                    .disabled(!checksAutomatically)
                    .onChange(of: installsAutomatically) {
                        updater?.automaticallyDownloadsUpdates = installsAutomatically
                    }
                Text(statement)
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Updates")
        }
        .onAppear {
            checksAutomatically = updater?.automaticallyChecksForUpdates ?? false
            installsAutomatically = updater?.automaticallyDownloadsUpdates ?? false
        }
    }

    private var statement: String {
        guard checksAutomatically else {
            return "Nothing is contacted until you choose Check for Updates… from the \(Branding.displayName) menu."
        }
        let what = installsAutomatically
            ? "New versions install themselves and take effect next launch."
            : "You are told when a new version exists and decide whether to install it."
        return "\(what) The check is a request to \(Branding.appcastURL) for a few KB of XML — no account, no identifier, and nothing about your photographs."
    }
}

// MARK: - Perception

/// What the app is actually running, and where it came from.
///
/// Worth a pane of its own because the honest answer changes between a release and a build from
/// source, and because "runs on your machine" is a claim someone should be able to check rather
/// than take on trust.
private struct PerceptionSettings: View {
    /// On by default (D14). The default lives in `PlaceNames.isEnabled` too; both read the same key,
    /// and the pane must never be the only thing that knows what the default is.
    @AppStorage(PlaceNames.enabledKey) private var placeNamesEnabled = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Model", value: PerceptionInfo.modelName)
                LabeledContent("Source", value: PerceptionInfo.sourceDescription)
                LabeledContent("Runs on", value: "This Mac — Apple Silicon GPU via MLX")
            } header: {
                Text("Scene reading")
            }

            Section {
                Text(PerceptionInfo.networkStatement)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                // Placed here, under Network, and not under a friendlier heading. This is the one
                // switch in the app that governs whether anything leaves the machine, and burying
                // it beside a cosmetic preference would be the wrong kind of quiet.
                Toggle("Look up place names for geotagged photos", isOn: $placeNamesEnabled)
                Text(placeNamesEnabled
                     ? "The coordinate is sent to Apple and a place name comes back, so the strip can "
                       + "say “Sunriver, Oregon” instead of degrees. Your photograph is not sent — not "
                       + "the pixels, not the filename. Coordinates are rounded to about 110 m first, "
                       + "and each place is looked up once and remembered."
                     : "Off. No coordinate ever leaves this Mac, and the strip groups by proximity and "
                       + "shows degrees.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !placeNamesEnabled, !PlaceNames.shared.names.isEmpty {
                    // Turning it off and keeping a list of everywhere someone has been would be
                    // exactly the kind of quiet this switch exists to prevent.
                    Button("Forget the \(PlaceNames.shared.names.count) place names already looked up") {
                        PlaceNames.shared.forgetAll()
                    }
                    .font(.caption)
                }
            } header: {
                Text("Network")
            }
        }
        .formStyle(.grouped)
    }
}

/// Reads what it can from the bundle rather than restating it, so this pane cannot drift out of
/// agreement with the build it is inside.
enum PerceptionInfo {
    /// Whether the weights travelled with the app. The packaging script refuses to make a signed
    /// build without them, so for anything a user installs this is true.
    static var isBundled: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(
            atPath: resources.appendingPathComponent("PerceptionModel/config.json").path)
    }

    static var modelName: String {
        // The repo id without the org prefix: "Qwen3.5-2B-MLX-4bit" is the useful half.
        let id = ProcessInfo.processInfo.environment["KELVIN_MODEL"]
            ?? MLXPerceptionProvider.defaultModelID
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Weights loaded from an explicit path rather than the Hugging Face cache — what
    /// `make app-staged` does. Neither bundled nor downloaded, and saying "downloaded" here was
    /// simply untrue: nothing had been fetched.
    static var localPath: String? {
        guard !isBundled,
              let path = ProcessInfo.processInfo.environment["KELVIN_MODEL_PATH"],
              !path.isEmpty else { return nil }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    static var sourceDescription: String {
        if isBundled { return "Included in the app" }
        if let path = localPath { return path }
        return "Downloaded once to ~/.cache/huggingface"
    }

    /// Said as a CAPABILITY — "needs no network" — rather than as a promise about behaviour.
    /// "Makes no network requests" is true today and would quietly become false the moment an
    /// update check ships, and a claim a packet capture can disprove is worth more trouble than
    /// it buys. What the user actually wants to know is that the reading happens here.
    static var networkStatement: String {
        if isBundled {
            return "The model is inside the app, so reading a photograph needs no network at all. No account, no telemetry."
        }
        if localPath != nil {
            return "Reading the model from a folder on this Mac — nothing was downloaded. No account, no telemetry."
        }
        return "Built from source, so the model was fetched once from Hugging Face at a pinned revision. Reading a photograph runs here. No account, no telemetry."
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppInfo.versionLine)
                LabeledContent("Licence", value: Branding.licenceName)
                // Copyright exists the moment something is written — no notice is required for it
                // to hold. It is here because a copyleft licence is a grant of rights BY someone,
                // and a reader who cannot see who is granting them cannot rely on them.
                LabeledContent("Copyright", value: Branding.copyright)
            }

            Section {
                if let source = URL(string: Branding.repositoryURL) {
                    Link("Source code", destination: source)
                }
                if let releases = URL(string: Branding.releasesURL) {
                    Link("Releases", destination: releases)
                }
                // Prefilled with the three things a report is useless without, and which nobody
                // enjoys typing: the build, the macOS version and the chip. The field names match
                // the ids in .github/ISSUE_TEMPLATE/bug_report.yml — rename one there and it stops
                // prefilling, which is the trade for not asking the reporter to look them up.
                Link("Report a bug", destination: AppInfo.bugReportURL)
                Link("Request a feature", destination: AppInfo.featureRequestURL)
            } header: {
                Text("Links")
            } footer: {
                Text("These open in your browser. \(Branding.displayName) does not contact them itself.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let sponsor = Branding.sponsorURL, let url = URL(string: sponsor) {
                Section {
                    Link("Support development", destination: url)
                    // The names ship inside the build (Branding.sponsors) rather than being
                    // fetched, because "no network requests" does not have a thank-you exception.
                    ForEach(Branding.sponsors, id: \.self) { name in
                        Text(name)
                    }
                } header: {
                    Text(Branding.sponsors.isEmpty ? "Support" : "Support — with thanks to")
                } footer: {
                    if !Branding.sponsors.isEmpty {
                        Text("Sponsors as of this release. The list ships in the app and is never fetched.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum AppInfo {
    /// "0.1.0 (139)", or "dev build" under `swift run`, where there is no Info.plist to read.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "dev build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Apple Silicon or Intel, which changes what a crash means often enough to be worth reporting.
    static var architecture: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.hasPrefix("arm") ? "Apple Silicon" : "Intel"
    }

    static var bugReportURL: URL {
        issueURL(template: "bug_report.yml", extra: [
            URLQueryItem(name: "macos", value: osVersion),
            URLQueryItem(name: "mac", value: architecture)
        ])
    }

    /// A feature request, prefilled with the build so a request from an old version is legible as
    /// one rather than looking like a comment on the current app.
    static var featureRequestURL: URL {
        issueURL(template: "feature_request.yml")
    }

    private static func issueURL(template: String, extra: [URLQueryItem] = []) -> URL {
        // Branding's URLs are compile-time constants, so neither fallback is reachable — they
        // exist because the convention is no force-unwraps outside tests, without exceptions.
        var components = URLComponents(string: Branding.issuesURL + "/new") ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(name: "build", value: versionLine)
        ] + extra
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
