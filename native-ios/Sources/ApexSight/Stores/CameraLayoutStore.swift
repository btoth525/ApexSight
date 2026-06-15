import Foundation

/// Persists the user's custom camera ordering and which cameras are hidden from the main
/// Cameras wall. Stored in the app group so the arrangement survives relaunches.
@MainActor
final class CameraLayoutStore: ObservableObject {
    @Published private(set) var order: [String] = []
    @Published private(set) var hidden: Set<String> = []

    private let orderKey = "apex.cameraOrder"
    private let hiddenKey = "apex.cameraHidden"
    private var defaults: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    init() { load() }

    private func load() {
        order = defaults?.stringArray(forKey: orderKey) ?? []
        hidden = Set(defaults?.stringArray(forKey: hiddenKey) ?? [])
    }

    private func save() {
        defaults?.set(order, forKey: orderKey)
        defaults?.set(Array(hidden), forKey: hiddenKey)
    }

    func isHidden(_ name: String) -> Bool { hidden.contains(name) }

    /// All cameras arranged by the saved order; cameras not yet in the order (newly added on
    /// the server) are appended alphabetically so nothing ever disappears.
    func arranged(_ cameras: [FrigateCamera]) -> [FrigateCamera] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return cameras.sorted { a, b in
            switch (rank[a.name], rank[b.name]) {
            case let (.some(x), .some(y)): return x < y
            case (.some, .none):           return true
            case (.none, .some):           return false
            case (.none, .none):           return a.name < b.name
            }
        }
    }

    /// Visible cameras (hidden removed) in the saved order — what the wall renders.
    func visible(_ cameras: [FrigateCamera]) -> [FrigateCamera] {
        arranged(cameras).filter { !hidden.contains($0.name) }
    }

    /// Commit a new arrangement from edit mode.
    func commit(order names: [String], hidden newHidden: Set<String>) {
        order = names
        hidden = newHidden
        save()
    }
}
