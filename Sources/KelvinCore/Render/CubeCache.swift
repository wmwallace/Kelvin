import Foundation

/// A small, bounded, thread-safe memo of colour-cube tables, keyed by the recipe values that
/// define them.
///
/// Every cube Kelvin bakes — HSL, black-and-white, colour and luminance selections — is 32³
/// colour conversions and a fresh half-megabyte `Data`, and each was rebuilt on every render.
/// That is every tick of a slider drag in the app, where the HSL or mono settings are exactly the
/// thing NOT being dragged, and four times over for a candidate strip that shares its looks. The
/// table is a pure function of a handful of numbers, so the same numbers get the same table.
///
/// **A lock, not an actor.** The renderer is synchronous and runs on `Offload` lanes, several at
/// once (preview, candidates, export); an actor would force it to `await` inside a pure function,
/// and hopping onto the cooperative pool from a lane is the pattern D21 exists to forbid. The lock
/// guards two dictionary operations and is never held while a table is built, so two lanes baking
/// different cubes never wait on each other; two lanes baking the same new cube may both build it
/// once, which costs a millisecond and returns identical bytes.
///
/// **Bounded**, least-recently-used out. A table is 512 KB, and a session that auditions every look
/// on every frame would otherwise keep all of them forever.
final class CubeCache<Key: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Key: Data] = [:]
    /// Keys from least to most recently used. Capacities are single digits, so a linear scan to
    /// reorder costs nothing next to the conversions it saves.
    private var order: [Key] = []
    let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// The table for `key`, built by `build` only when it is not already held. A nil build is
    /// returned and not remembered.
    func data(for key: Key, build: (Key) -> Data?) -> Data? {
        lock.lock()
        if let hit = entries[key] {
            touch(key)
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let built = build(key) else { return nil }

        lock.lock()
        defer { lock.unlock() }
        if let raced = entries[key] {
            // Another lane built the same table while this one did; keep one copy.
            touch(key)
            return raced
        }
        entries[key] = built
        order.append(key)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        return built
    }

    /// How many tables are held. For tests.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    private func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}
