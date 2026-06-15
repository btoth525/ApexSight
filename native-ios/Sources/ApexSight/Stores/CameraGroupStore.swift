import Foundation

/// Persists user-defined camera groups in the app group so saved grids survive
/// relaunches (and could later be shared with widgets).
@MainActor
final class CameraGroupStore: ObservableObject {
    @Published var groups: [CameraGroup] = []

    private let key = "apex.cameraGroups"
    private var defaults: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    init() {
        load()
    }

    func add(name: String, cameraNames: [String], columns: Int) {
        groups.append(CameraGroup(name: name, cameraNames: cameraNames, columns: columns))
        save()
    }

    func update(_ group: CameraGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        save()
    }

    func delete(at offsets: IndexSet) {
        groups.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        defaults?.set(data, forKey: key)
    }

    private func load() {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CameraGroup].self, from: data) else { return }
        groups = decoded
    }
}
