import SwiftUI
import AppKit
import KelvinCore

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

    var body: some View {
        TabView {
            GeneralSettings(appState: appState)
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

    var body: some View {
        Form {
            Section {
                Toggle("Include the rest of the folder when opening a photo",
                       isOn: $appState.includeFolderOnOpen)
                Text(appState.includeFolderOnOpen
                     ? "The other photos are listed in the filmstrip. Nothing is read from them until the strip is open."
                     : "Only the photo you choose — no filmstrip, no arrow keys. Batch apply is unaffected; it asks for its own folder.")
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
        }
        .formStyle(.grouped)
    }
}

// MARK: - Perception

/// What the app is actually running, and where it came from.
///
/// Worth a pane of its own because the honest answer changes between a release and a build from
/// source, and because "runs on your machine" is a claim someone should be able to check rather
/// than take on trust.
private struct PerceptionSettings: View {
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
        let id = ProcessInfo.processInfo.environment["KELVIN_MODEL"] ?? "mlx-community/Qwen3.5-2B-MLX-4bit"
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    static var sourceDescription: String {
        isBundled ? "Included in the app" : "Downloaded once to ~/.cache/huggingface"
    }

    static var networkStatement: String {
        isBundled
            ? "This build makes no network requests. The model is inside the app, your photographs never leave this Mac, and there is no account, telemetry or crash reporting."
            : "Built from source, so the model was downloaded once from Hugging Face at a fixed revision. Your photographs never leave this Mac, and there is no account, telemetry or crash reporting."
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
                Link("Source code", destination: URL(string: Branding.repositoryURL)!)
                Link("Releases", destination: URL(string: Branding.releasesURL)!)
                // Prefilled with the three things a report is useless without, and which nobody
                // enjoys typing: the build, the macOS version and the chip. The field names match
                // the ids in .github/ISSUE_TEMPLATE/bug_report.yml — rename one there and it stops
                // prefilling, which is the trade for not asking the reporter to look them up.
                Link("Report a bug", destination: AppInfo.bugReportURL)
            } header: {
                Text("Links")
            } footer: {
                Text("These open in your browser. \(Branding.displayName) does not contact them itself.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let sponsor = Branding.sponsorURL, let url = URL(string: sponsor) {
                Section {
                    Link("Support development", destination: url)
                } header: {
                    Text("Support")
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
        var components = URLComponents(string: Branding.issuesURL + "/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "build", value: versionLine),
            URLQueryItem(name: "macos", value: osVersion),
            URLQueryItem(name: "mac", value: architecture)
        ]
        return components.url ?? URL(string: Branding.issuesURL)!
    }
}
