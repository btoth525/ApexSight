import Foundation

/// Watches thermal + Low-Power state so the camera wall can shed its most expensive work —
/// N simultaneous live HLS decodes — when the device is hot or conserving battery. Under
/// pressure the wall shows the latest snapshot instead of a live decode; live resumes
/// automatically the moment conditions clear. The 4-up HLS wall is the dominant heat/energy
/// source, so backing it off is where the win is.
@MainActor
final class ThermalMonitor: ObservableObject {
    static let shared = ThermalMonitor()

    /// True when we should drop live decoding: a `.serious`/`.critical` thermal state, or
    /// Low Power Mode. Views observe this and fall back to snapshots while it's true.
    @Published private(set) var shouldReduceLoad = false

    /// Why we're reducing — surfaced to the user as a small badge so the snapshot fallback
    /// reads as intentional ("Power Saving" / "Cooling") rather than a stuck/broken tile.
    @Published private(set) var reason: String?

    private var observers: [NSObjectProtocol] = []

    private init() {
        recompute()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        })
        observers.append(nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func recompute() {
        let info = ProcessInfo.processInfo
        let hot = info.thermalState == .serious || info.thermalState == .critical
        let lowPower = info.isLowPowerModeEnabled
        shouldReduceLoad = hot || lowPower
        reason = hot ? "Cooling" : (lowPower ? "Power Saving" : nil)
    }
}
