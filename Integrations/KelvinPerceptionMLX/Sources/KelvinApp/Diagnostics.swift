import Foundation
import SwiftUI
import AppKit

// Instruments for the one bug the release notes admit to: "the edit panel can stutter while a
// render or scene read is in flight".
//
// Everything else in this app is measured by `kelvin-cli bench*`, headlessly, because the work is
// in Core. This one cannot be: the symptom is a main thread that is busy when it should be drawing,
// and neither the renderer nor the engine can see that. So the measurement lives here, beside the
// only run loop that has the problem.
//
// Both hooks are off unless their environment variable is set. Nothing here runs in a shipped copy.

/// How late the main run loop is, sampled from the main run loop itself.
///
/// This measures the SYMPTOM rather than any theory about the cause. A timer scheduled every 8 ms
/// in `.common` mode can only fire late if something else is occupying the thread that draws the
/// window — so the lateness *is* the stutter, whatever produced it. Anything the profile blames has
/// to move this number to count as a fix.
///
/// `.common` is load-bearing: in `.default` mode a timer stops firing during scroll tracking and
/// menu tracking, which is precisely when the panel is reported to stutter.
@MainActor
final class HitchMonitor {
    static let shared = HitchMonitor()
    static var enabled: Bool { ProcessInfo.processInfo.environment["KELVIN_TRACE_HITCHES"] != nil }

    /// One frame at 60 Hz. Two of them late is a stutter a person can see.
    private let frame = 1.0 / 60.0
    private var timer: Timer?
    /// Kept alive for the lifetime of the monitor. WITHOUT IT THIS INSTRUMENT LIES.
    ///
    /// The first run of this monitor reported the main thread blocked for 30% of launch, with
    /// stalls over a second — and a `sample` of the process during those exact seconds found the
    /// main thread parked in `mach_msg`, idle, 98% of the time. Both were true: the app was not
    /// busy, and the timer really was not firing. macOS throttles and coalesces timers for an app
    /// that is not frontmost, which a benchmark run from a terminal never is. So the measurement
    /// was of App Nap, not of Kelvin.
    ///
    /// `beginActivity` opts out for as long as the token is held, and a zero tolerance stops the
    /// system from sliding the fire dates to save power. Lesson worth keeping: an instrument that
    /// measures "was the thread late" has to prove the thread was *asked* on time.
    private var activity: NSObjectProtocol?
    private var last = Date()
    private var samples = 0
    private var hitches: [Double] = []          // how long the thread was unavailable, ms
    private var worst = 0.0
    private var started = Date()

    /// `KELVIN_TRACE_HITCHES=<seconds>` reports and exits after that long, so the load path — decode,
    /// the scene read, candidate generation — can be measured by a script rather than by watching.
    private var deadline: Double? {
        ProcessInfo.processInfo.environment["KELVIN_TRACE_HITCHES"].flatMap(Double.init)
    }

    func start() {
        guard Self.enabled, timer == nil else { return }
        started = Date(); last = Date()
        if let seconds = deadline, seconds > 1 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self.report("first \(Int(seconds))s — launch, scene read, candidates")
                exit(0)
            }
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "main-thread hitch tracing")
        let t = Timer(timeInterval: frame / 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
        FileHandle.standardError.write(Data("hitch monitor: watching the main run loop\n".utf8))
    }

    private func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(last) * 1000
        last = now
        samples += 1
        // The scheduled interval is 8.3 ms, so a gap over 33 ms means the thread was gone for two
        // frames or more. Below that a timer's own jitter dominates and would only add noise.
        if gap > 33 {
            hitches.append(gap); worst = max(worst, gap)
            // WHEN matters as much as how much. A total says the thread is busy; a timeline says
            // whether it is busy while the model loads, while the scene is read, or while
            // candidates render — which are three different pieces of code to look at.
            let line = String(format: "  hitch at %6.1fs: %5.0f ms\n",
                              now.timeIntervalSince(started), gap)
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    /// A line that says whether the thread was available, and for how long it was not.
    func report(_ label: String) {
        let elapsed = Date().timeIntervalSince(started)
        let blocked = hitches.reduce(0, +)
        let sorted = hitches.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let line = String(
            format: "hitches [%@]: %d stalls over %.1fs — %.0f ms blocked (%.1f%%), median %.0f ms, worst %.0f ms\n",
            label, hitches.count, elapsed, blocked, blocked / (elapsed * 1000) * 100, median, worst)
        FileHandle.standardError.write(Data(line.utf8))
    }

    func reset() { hitches = []; worst = 0; samples = 0; started = Date(); last = Date() }
}

/// Wall time spent inside named pieces of main-actor work, so a stall can be attributed to Kelvin's
/// own code or to what SwiftUI does afterwards. Off unless `KELVIN_TRACE_HITCHES` is set.
@MainActor
enum MainWork {
    private static var totals: [String: (n: Int, ms: Double, worst: Double)] = [:]

    static func time<T>(_ label: String, _ body: () -> T) -> T {
        guard HitchMonitor.enabled else { return body() }
        let start = Date()
        let out = body()
        let ms = Date().timeIntervalSince(start) * 1000
        var t = totals[label] ?? (0, 0, 0)
        t.n += 1; t.ms += ms; t.worst = max(t.worst, ms)
        totals[label] = t
        return out
    }

    /// For work that happened somewhere else and is being reported back — a detached render, say,
    /// whose duration is only known off the main actor.
    static func record(_ label: String, ms: Double) {
        guard HitchMonitor.enabled else { return }
        var t = totals[label] ?? (0, 0, 0)
        t.n += 1; t.ms += ms; t.worst = max(t.worst, ms)
        totals[label] = t
    }

    static func report() {
        guard HitchMonitor.enabled else { return }
        for (label, t) in totals.sorted(by: { $0.value.ms > $1.value.ms }) {
            let line = String(format: "  %-24@ %5d calls, %8.0f ms total, %6.1f ms mean, %6.0f ms worst\n",
                              label as NSString, t.n, t.ms, t.ms / Double(t.n), t.worst)
            FileHandle.standardError.write(Data(line.utf8))
        }
        totals = [:]
    }
}

/// CPU actually burned on the main thread, from the kernel rather than from a timer.
///
/// The lateness monitor above answers "was the thread available", which conflates being BUSY with
/// being throttled — and a benchmark app is throttled in ways a frontmost one is not. This answers
/// the other half: how much of the wall clock did the thread that draws the window spend executing?
/// If lateness is high and this is low, the work is not on the main thread and no amount of
/// refactoring views will help.
@MainActor
enum MainThreadCPU {
    static func seconds() -> Double {
        var info = thread_basic_info()
        // THREAD_BASIC_INFO_COUNT is a C macro and does not survive into Swift.
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mach_thread_self(), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
             + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }
}

/// A slider drag, without a hand.
///
/// The stutter is reported while dragging, and a drag cannot be automated from outside the process
/// — so it is automated from inside. Each step writes one adjustment and calls `onEdit()`, which is
/// exactly what `ToneSlider`'s binding does, at the rate a trackpad produces events. What it cannot
/// reproduce is AppKit's own event handling, so treat the result as a floor.
///
///   KELVIN_DEMO_IMAGE=photo.jpg KELVIN_TRACE_HITCHES=1 KELVIN_STRESS_DRAG=180 swift run kelvin-app
///
/// With `KELVIN_STRESS_EXIT=1` the process reports and exits, which makes it usable from a script.
@MainActor
enum StressDrag {
    static var steps: Int? {
        ProcessInfo.processInfo.environment["KELVIN_STRESS_DRAG"].flatMap(Int.init)
    }
    static var exitsWhenDone: Bool {
        ProcessInfo.processInfo.environment["KELVIN_STRESS_EXIT"] != nil
    }

    /// Sweeps exposure across ±1 EV at 60 Hz, the way a hand does when it is looking for the value.
    static func run(steps: Int, apply: @escaping (Double) -> Void) async {
        HitchMonitor.shared.reset()
        let cpuStart = MainThreadCPU.seconds()
        let wallStart = Date()
        var applyMs = 0.0, sleepMs = 0.0
        for i in 0..<steps {
            let phase = Double(i) / 30.0
            let a = Date()
            apply(sin(phase) * 1.0)
            let b = Date()
            try? await Task.sleep(nanoseconds: 16_666_667)
            let c = Date()
            applyMs += b.timeIntervalSince(a) * 1000
            sleepMs += c.timeIntervalSince(b) * 1000
        }
        // Which half of a step is slow says whether the thread is BUSY (the write blocks) or merely
        // UNAVAILABLE (a 16 ms sleep takes far longer to be resumed, because the main actor is
        // occupied by something the write only scheduled).
        let cpu = MainThreadCPU.seconds() - cpuStart
        let wall = Date().timeIntervalSince(wallStart)
        FileHandle.standardError.write(Data(String(
            format: "  per step: apply %.1f ms, sleep-resume %.1f ms (asked for 16.7)\n" +
                    "  main thread burned %.2fs of CPU over %.2fs wall = %.0f%% busy\n",
            applyMs / Double(steps), sleepMs / Double(steps),
            cpu, wall, cpu / wall * 100).utf8))
        HitchMonitor.shared.report("drag of \(steps) steps")
        MainWork.report()
        // Through the app's own quit path, never a bare `exit(0)`: the read-ahead is usually
        // generating when the drag finishes, and `exit()` under a live MLX generation aborts in
        // Metal (`addCompletedHandler` after commit) — a crash report for a successful run.
        // As a run-loop block, not from inside this task: `terminate` spins a nested run loop
        // waiting for the delegate's reply, and that loop can only run main-actor work if the
        // actor is free — which, from inside a task, it is not. Found the hard way.
        if exitsWhenDone {
            RunLoop.main.perform { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
        }
    }
}
