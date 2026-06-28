import Foundation

/// Limits how many live streams negotiate + begin decoding at the same time.
///
/// A wall of cameras would otherwise have every tile call `model.start()` the instant it
/// appears, so on a cold launch all feeds stampede the network and the hardware decoders at
/// once — which is the dominant launch/scroll cost. Each tile `acquire()`s a slot before
/// starting and `release()`s it once it's playing (or after a short safety timeout), so starts
/// roll out a few at a time and the wall comes up fast and smooth.
actor StreamGate {
    static let shared = StreamGate(limit: 3)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Suspend until a startup slot is free.
    ///
    /// INVARIANT — every `acquire()` MUST be paired with exactly one later `release()`, even
    /// when the caller's Task is cancelled while suspended here. A cancelled waiter is not
    /// dropped from `waiters`: it stays queued, is eventually resumed by some `release()`
    /// (which transfers it a slot — `active` unchanged), and the caller's own
    /// `guard !Task.isCancelled … else { releaseGate(); return }` then returns that slot. This
    /// keeps `active` balanced. Resuming a cancelled waiter early *without* a matching slot
    /// transfer would let its paired `release()` free a permit it never held — over-admitting
    /// past `limit` — so deliberately DON'T add a cancellation handler that pops the waiter.
    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // Resumed by release(), which hands its slot straight to us (active count unchanged).
    }

    /// Return a slot; hand it directly to the next waiter if any, else free it.
    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}
