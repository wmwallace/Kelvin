import Foundation
@preconcurrency import CoreImage
import KelvinCore

/// The app's scene reader: Apple's Vision framework, through `VisionPerceptionProvider` (D27).
///
/// It stands where `MLXPerceptionProvider` stood and answers the same questions the rest of the app
/// asks of it — what it is called for the cache key, whether it is working right now for the quit
/// path — so the switch touched one declaration rather than every call site. There is nothing to
/// preload: Vision's models ship with the OS and a read takes a tenth of a second, which is why the
/// fifteen-second launch warm-up is gone rather than moved.
final class SceneReader: Sendable {
    private let provider = VisionPerceptionProvider()
    private let inFlight = Counter()

    /// What `PerceptionStore` keys a read on. A Vision read and one of the old model's reads of the
    /// same photograph are different reads, and must never be served for each other.
    var activeModelID: String { provider.identifier }

    /// A read is in progress. The quit path waits on it the way it waited on the model.
    var isBusy: Bool { inFlight.value > 0 }
    /// Kept for the quit path's second question, which for the model meant "generating tokens" —
    /// for Vision, the same thing as busy.
    var isGenerating: Bool { isBusy }

    func perceive(_ image: CIImage) async throws -> Perception {
        inFlight.add(1)
        defer { inFlight.add(-1) }
        // `VisionPerceptionProvider.perceive` hops to its own serial queue: Vision blocks the thread
        // it runs on, and D21 keeps that off the cooperative pool.
        return try await provider.perceive(image)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func add(_ d: Int) { lock.withLock { n += d } }
    }
}
