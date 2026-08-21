import Foundation
import KelvinCore
import os

/// "Kelvin quit unexpectedly last time" — said by Kelvin, once, rather than left to a system dialog
/// nobody reads and a report in a folder nobody opens.
///
/// The quit bugs of 21 August 2026 (D21) were reported as "it doesn't always quit" because every
/// crash on the way out looked, from the outside, like a quit. The reports were there all along, in
/// `~/Library/Logs/DiagnosticReports`, and nothing connected them to the app. This looks for one
/// newer than the previous launch and says so in the status line, with where to send it. It reads
/// a directory listing and nothing else — no report is opened, nothing leaves the machine.
enum CrashNotice {
    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "Lifecycle")
    private static let lastLaunchKey = "diagnostics.lastLaunchAt"

    /// The message for the status line, or nil when the last run ended normally (or this is the
    /// first run, which has nothing to compare against). Records this launch either way.
    static func check() async -> String? {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: lastLaunchKey) as? Date
        defaults.set(Date(), forKey: lastLaunchKey)
        guard let previous else { return nil }
        let process = ProcessInfo.processInfo.processName
        let reports = await Offload.run(.io, qos: .utility) { () -> [String] in
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }
            return names.filter { url in
                guard url.lastPathComponent.hasPrefix(process),
                      let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                          .contentModificationDate else { return false }
                return date > previous
            }.map(\.lastPathComponent)
        }
        guard !reports.isEmpty else { return nil }
        log.fault("the previous run ended in a crash: \(reports.joined(separator: ", "), privacy: .public)")
        return "\(Branding.displayName) quit unexpectedly last time — Help ▸ Report a Bug… and attach the newest kelvin-app report from ~/Library/Logs/DiagnosticReports"
    }
}
