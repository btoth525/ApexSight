import Foundation

@MainActor
final class NotificationTriggerStore: ObservableObject {
    @Published private(set) var triggers: [NotificationTrigger] = []

    private let key = "apex.notificationTriggers"
    private var defaults: UserDefaults? { UserDefaults(suiteName: "group.com.brandontoth.apexsight") }

    init() { load() }

    private func load() {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NotificationTrigger].self, from: data)
        else { return }
        triggers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(triggers) else { return }
        defaults?.set(data, forKey: key)
    }

    func add(_ trigger: NotificationTrigger) {
        triggers.append(trigger)
        save()
    }

    func update(_ trigger: NotificationTrigger) {
        guard let idx = triggers.firstIndex(where: { $0.id == trigger.id }) else { return }
        triggers[idx] = trigger
        save()
    }

    func delete(at offsets: IndexSet) {
        triggers.remove(atOffsets: offsets)
        save()
    }

    func toggleEnabled(_ trigger: NotificationTrigger) {
        guard let idx = triggers.firstIndex(where: { $0.id == trigger.id }) else { return }
        triggers[idx].enabled.toggle()
        save()
    }
}
