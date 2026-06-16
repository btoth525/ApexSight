import SwiftUI

/// GUI control panel for how notifications look — synced to the relay so it shapes
/// even app-closed instant pushes. Inspired by the SgtBatten Frigate blueprint.
struct AlertStyleView: View {
    @StateObject private var store = NotificationStyleStore()
    @State private var newLabel = ""
    @State private var newEmoji = ""

    /// Built-in emoji map (mirror of the relay's defaults) for the live preview.
    private static let baseEmoji: [String: String] = [
        "amazon": "📦", "ups": "📦", "usps": "📮", "fedex": "✈️", "dhl": "📬",
        "face": "🙂", "known_face": "😎", "recognized_face": "😎", "unknown_face": "🤔",
        "license_plate": "🅿️", "plate": "🅿️", "lpr": "🅿️",
        "person": "🚶", "car": "🚗", "truck": "🚚", "motorcycle": "🏍️", "bicycle": "🚲",
        "bus": "🚌", "package": "📦", "dog": "🐕", "cat": "🐈", "bird": "🐦",
        "deer": "🦌", "bear": "🐻", "doorbell": "🔔",
    ]

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(spacing: 16) {
                    previewCard
                    contentCard
                    fieldsCard
                    mediaCard
                    emojiCard
                    Text("Changes sync to your push relay automatically, so they apply even when the app is closed.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GlassTheme.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(16)
            }
        }
        .navigationTitle("Alert Style")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task { await store.sync() }
    }

    private var s: NotificationStyle { store.style }

    // MARK: - Preview

    private var previewCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("PREVIEW")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(GlassTheme.tertiary)
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(width: 54, height: 54)
                        .overlay {
                            Image(systemName: s.firstFrame == "none" ? "bell.fill" : "photo.fill")
                                .foregroundStyle(GlassTheme.secondary)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(previewTitle)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(GlassTheme.primary)
                            .lineLimit(1)
                        Text(previewBody)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(GlassTheme.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var previewTitle: String {
        let keys = ["amazon", "person"]
        var parts: [String] = []
        if s.severityPrefix { parts.append("🚨") }
        if s.showEmojis {
            var emojis: [String] = []
            for k in keys {
                if let e = mergedEmoji[k], !emojis.contains(e) { emojis.append(e) }
            }
            parts.append(emojis.isEmpty ? "⚠️" : emojis.joined(separator: " "))
        }
        parts.append("Front Driveway")
        return parts.joined(separator: " ")
    }

    private var previewBody: String {
        let ordered = s.subLabelFirst ? ["Amazon", "Person"] : ["Person", "Amazon"]
        var fields: [String] = []
        if s.showEntities { fields.append(ordered.joined(separator: s.fieldSeparator)) }
        if s.showZone { fields.append("Zone: Driveway") }
        if s.showConfidence { fields.append("94%") }
        if s.showTime { fields.append("3:42 PM") }
        return fields.joined(separator: s.fieldSeparator)
    }

    private var mergedEmoji: [String: String] {
        Self.baseEmoji.merging(s.emojiMap) { _, user in user }
    }

    // MARK: - Cards

    private var contentCard: some View {
        card("Content") {
            toggle("Sub-label first", "Recognized face / plate / carrier headlines the alert", isOn: bind(\.subLabelFirst))
            toggle("Severity prefix", "Show 🚨 in front of alert-level titles", isOn: bind(\.severityPrefix))
            toggle("Emojis", "Classify objects with emojis in the title", isOn: bind(\.showEmojis))
        }
    }

    private var fieldsCard: some View {
        card("Message fields") {
            toggle("Objects / entities", "e.g. Amazon · Person", isOn: bind(\.showEntities))
            toggle("Zone", "Which zone the object was in", isOn: bind(\.showZone))
            toggle("Confidence", "Detection score percentage", isOn: bind(\.showConfidence))
            toggle("Time", "When it happened", isOn: bind(\.showTime))
            HStack {
                Text("Separator")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
                Picker("Separator", selection: bind(\.fieldSeparator)) {
                    Text("·").tag(" · ")
                    Text("•").tag(" • ")
                    Text("—").tag(" — ")
                    Text("|").tag(" | ")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
    }

    private var mediaCard: some View {
        card("Media") {
            HStack {
                Text("First frame")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
                Picker("First frame", selection: bind(\.firstFrame)) {
                    Text("Cropped").tag("cropped")
                    Text("Full").tag("full")
                    Text("None").tag("none")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            Text("The image shown the instant the alert arrives. \"Cropped\" zooms to the object's box.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GlassTheme.tertiary)
            toggle("Final GIF update", "When the event ends, swap in the full animated GIF (same notification, no duplicate)", isOn: bind(\.finalGif))
        }
    }

    private var emojiCard: some View {
        card("Custom emojis") {
            Text("Override or add label → emoji mappings (e.g. your family members or pets).")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GlassTheme.tertiary)

            ForEach(s.emojiMap.sorted(by: { $0.key < $1.key }), id: \.key) { key, emoji in
                HStack {
                    Text(emoji).font(.system(size: 20))
                    Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Button {
                        store.style.emojiMap.removeValue(forKey: key)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(GlassTheme.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(key) emoji")
                }
            }

            HStack(spacing: 8) {
                TextField("label (e.g. taylor)", text: $newLabel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, weight: .semibold))
                    .padding(10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                TextField("😎", text: $newEmoji)
                    .font(.system(size: 16))
                    .frame(width: 56)
                    .padding(10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    let label = newLabel.trimmingCharacters(in: .whitespaces).lowercased()
                    let emoji = newEmoji.trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty, !emoji.isEmpty else { return }
                    store.style.emojiMap[label] = emoji
                    newLabel = ""; newEmoji = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(GlassTheme.cyan)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add emoji mapping")
            }
        }
    }

    // MARK: - Helpers

    private func bind<T>(_ keyPath: WritableKeyPath<NotificationStyle, T>) -> Binding<T> {
        Binding(
            get: { store.style[keyPath: keyPath] },
            set: { store.style[keyPath: keyPath] = $0 }
        )
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                content()
            }
        }
    }

    private func toggle(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GlassTheme.primary)
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GlassTheme.tertiary)
            }
        }
        .tint(GlassTheme.cyan)
    }
}
