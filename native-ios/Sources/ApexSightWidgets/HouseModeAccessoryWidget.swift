import WidgetKit
import SwiftUI

// Lock Screen (and StandBy) accessory widget for the house mode — a glanceable arm-status shield
// that taps straight into the House Mode control. Reads the app-group mirror written by the app on
// every relay poll (SharedHouseMode); refreshed the moment the mode changes via ApexSurfaceRefresh.

struct HouseModeEntry: TimelineEntry {
    let date: Date
    let mode: String
    let armedBy: String
}

struct HouseModeProvider: TimelineProvider {
    func placeholder(in context: Context) -> HouseModeEntry {
        HouseModeEntry(date: Date(), mode: "home", armedBy: "")
    }

    func getSnapshot(in context: Context, completion: @escaping (HouseModeEntry) -> Void) {
        completion(HouseModeEntry(date: Date(), mode: SharedHouseMode.mode, armedBy: SharedHouseMode.armedBy))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HouseModeEntry>) -> Void) {
        // Verify against the relay on every timeline build — the app-group mirror is only written
        // while the APP runs, so without this a mode armed from HA/the keypad while the app was
        // closed left the widget stale until the next app open. Best-effort with a short timeout;
        // the cached mirror stands on failure. (The relay also silent-pushes every phone on a mode
        // change, which triggers this reload within seconds — this fetch is what makes it correct.)
        Task {
            let fresh = await SharedHouseModeFetch.refresh(reloadingSurfaces: false)
            let mode = fresh.isEmpty ? SharedHouseMode.mode : fresh
            let entry = HouseModeEntry(date: Date(), mode: mode, armedBy: SharedHouseMode.armedBy)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }
}

/// Accent per mode (Lock Screen renders accessory widgets tinted, so this reads as a subtle hue).
func modeColor(_ mode: String) -> Color {
    switch mode {
    case "home": return .green
    case "away": return .cyan
    case "night": return .indigo
    default: return .gray
    }
}

struct HouseModeAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HouseModeEntry

    private var mode: String { entry.mode }
    private var known: Bool { !mode.isEmpty }
    private var title: String { known ? SharedHouseMode.title(mode) : "House" }
    private var symbol: String { known ? SharedHouseMode.symbol(mode) : "shield.lefthalf.filled" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                    Text(known ? title : "Set")
                        .font(.system(size: 9, weight: .semibold))
                        .minimumScaleFactor(0.7)
                }
            }
            .widgetAccentable()

        case .accessoryInline:
            Label(known ? "House: \(title)" : "House Mode", systemImage: symbol)

        default: // .accessoryRectangular
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text(known ? title : "House Mode")
                        .font(.headline)
                    Text(known ? SharedHouseMode.subtitle(mode) : "Tap to arm or disarm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct HouseModeAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.brandontoth.apexsight.widget.housemode",
                            provider: HouseModeProvider()) { entry in
            HouseModeAccessoryView(entry: entry)
                .widgetURL(URL(string: "apex://house"))
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("House Mode")
        .description("Arm status at a glance — tap to change it.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
