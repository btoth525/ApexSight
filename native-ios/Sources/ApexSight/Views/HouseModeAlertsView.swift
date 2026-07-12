import SwiftUI

/// House Mode Alerts — the household's per-mode camera alert matrix.
///
/// One screen that answers "what alerts when?" and lets the user change it: for each house mode
/// (Home / Night / Away) every camera gets a toggle — ON = that camera pushes notifications while
/// the house is in that mode. Edits are HOUSEHOLD-WIDE: the map lives on the relay (one per pairing
/// code), every phone follows it, and the bridge mirrors it into Frigate's per-camera alert
/// switches so Home Assistant and the Frigate PWA agree with the app.
struct HouseModeAlertsView: View {
    @EnvironmentObject private var appState: AppState

    /// Working copy of the matrix (mode → muted cameras). Seeded from the relay map on appear,
    /// mutated by the toggles, pushed on every change (tiny payload, instant household sync).
    @State private var mutes: [String: [String]] = [:]
    @State private var seeded = false
    @State private var syncState: SyncState = .idle
    @State private var showResetConfirm = false

    private enum SyncState: Equatable { case idle, saving, synced, failed }

    private struct ModeSpec {
        let key: String
        let title: String
        let icon: String
        let tint: Color
        let blurb: String
    }

    private let modes: [ModeSpec] = [
        .init(key: "home", title: "Home", icon: "house.fill", tint: GlassTheme.green,
              blurb: "House disarmed — everyday mode"),
        .init(key: "night", title: "Night", icon: "moon.fill", tint: .indigo,
              blurb: "Armed for the night — perimeter watch"),
        .init(key: "away", title: "Away", icon: "lock.fill", tint: GlassTheme.orange,
              blurb: "Nobody home — everything alerts"),
    ]

    /// The relay's built-in per-mode mute defaults — MUST mirror the add-on's gate.MODE_MUTES.
    /// Used to seed the editor when the relay doesn't return a map yet (add-on older than 1.10.5),
    /// so the toggles show the TRUE behavior instead of a misleading everything-on.
    private static let defaultMutes: [String: [String]] = [
        "home":  ["Backyard_Wide", "Garage", "Living_Room_Wide", "Ryleighs_Rm",
                  "Side_Gate", "movie_room", "zachs_room"],
        "night": ["Living_Room_Wide", "Ryleighs_Rm", "movie_room", "zachs_room"],
        "away":  [],
    ]

    /// True when the relay hasn't reported a matrix — the add-on needs updating for edits to stick.
    private var relaySupportsMap: Bool { !appState.houseModeMap.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: GlassTheme.Space.l) {
                headerCard
                ForEach(modes, id: \.key) { spec in
                    modeCard(spec)
                }
                footerCard
            }
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.bottom, GlassTheme.Space.xxl)
        }
        .background(GlassBackground().ignoresSafeArea())
        .navigationTitle("House Mode Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { syncBadge } }
        .task {
            await appState.refreshHouseMode()
            seedIfNeeded()
        }
        .onChange(of: appState.houseModeMap) { _, _ in seedIfNeeded() }
        .confirmationDialog("Reset to recommended defaults?", isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Reset for the whole household", role: .destructive) {
                Task { await reset() }
            }
        } message: {
            Text("Home: Front Driveway + Doorbell · Night: adds Side Gate, Backyard, Garage · Away: every camera. Applies to everyone.")
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        VStack(spacing: GlassTheme.Space.m) {
            GlassCard {
                VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                    HStack(spacing: GlassTheme.Space.s) {
                        Image(systemName: "person.3.fill")
                            .font(.footnote)
                            .foregroundStyle(GlassTheme.accent)
                        Text("Applies to everyone in the household")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GlassTheme.primary)
                    }
                    Text("A camera with its switch ON sends alerts to every phone while the house is in that mode. Changes sync to all phones, the relay, and Home Assistant / Frigate.")
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !relaySupportsMap {
                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(GlassTheme.orange)
                    Text("Showing the current behavior. To EDIT it, update the ApexSight Push add-on to 1.10.5 in Home Assistant.")
                        .font(.caption)
                        .foregroundStyle(GlassTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(GlassTheme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GlassTheme.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip))
            }
        }
    }

    private func modeCard(_ spec: ModeSpec) -> some View {
        let isCurrent = appState.houseMode == spec.key
        return GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: spec.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(spec.tint)
                    Text(spec.title)
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                    if isCurrent {
                        Text("NOW")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(spec.tint.opacity(0.22), in: Capsule())
                            .foregroundStyle(spec.tint)
                    }
                    Spacer()
                    Text("\(alertCount(spec.key)) of \(roster.count) alert")
                        .font(.caption)
                        .foregroundStyle(GlassTheme.tertiary)
                }
                Text(spec.blurb)
                    .font(.caption)
                    .foregroundStyle(GlassTheme.tertiary)
                Divider().overlay(GlassTheme.separator)
                ForEach(roster, id: \.self) { camera in
                    Toggle(isOn: binding(mode: spec.key, camera: camera)) {
                        Text(titleize(camera))
                            .font(.subheadline)
                            .foregroundStyle(GlassTheme.primary)
                    }
                    .tint(spec.tint)
                    // Read-only until the relay can store edits (add-on 1.10.5+) — a toggle that
                    // silently reverts is worse than one that's visibly locked.
                    .disabled(!relaySupportsMap)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: GlassTheme.Radius.card)
                .stroke(isCurrent ? spec.tint.opacity(0.45) : .clear, lineWidth: 1.5)
        )
    }

    private var footerCard: some View {
        VStack(spacing: GlassTheme.Space.m) {
            if appState.houseModeMapIsCustom {
                Button {
                    showResetConfirm = true
                } label: {
                    Label("Reset to recommended defaults", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.secondary))
            }
            Text("New cameras alert in every mode until you turn them off here — nothing ever goes silent by accident.")
                .font(.caption2)
                .foregroundStyle(GlassTheme.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var syncBadge: some View {
        switch syncState {
        case .idle:
            EmptyView()
        case .saving:
            ProgressView().controlSize(.small)
        case .synced:
            Label("Synced", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GlassTheme.green)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label("Retry", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GlassTheme.red)
        }
    }

    // MARK: - Data plumbing

    /// Every camera the app knows (live Frigate list), falling back to any camera named in the
    /// relay map so the editor still renders before the camera list loads.
    private var roster: [String] {
        let live = appState.cameras.map(\.name)
        if !live.isEmpty { return live }
        var seen: [String] = []
        for (_, cams) in appState.houseModeMap {
            for c in cams where !seen.contains(c) { seen.append(c) }
        }
        return seen
    }

    private func alertCount(_ mode: String) -> Int {
        let muted = Set(mutes[mode] ?? [])
        return roster.filter { !muted.contains($0) }.count
    }

    private func seedIfNeeded() {
        guard !seeded else {
            // Upgrade the seed in place if the relay map arrives after we fell back to defaults.
            if relaySupportsMap, mutes == Self.defaultMutes, appState.houseModeMap != mutes {
                mutes = appState.houseModeMap
            }
            return
        }
        // Relay map when available; otherwise the built-in defaults — the toggles must always show
        // the TRUE per-mode behavior, never a misleading everything-on.
        mutes = relaySupportsMap ? appState.houseModeMap : Self.defaultMutes
        seeded = true
    }

    private func binding(mode: String, camera: String) -> Binding<Bool> {
        Binding(
            get: { !(mutes[mode] ?? []).contains(camera) },
            set: { alerts in
                var list = mutes[mode] ?? []
                if alerts {
                    list.removeAll { $0 == camera }
                } else if !list.contains(camera) {
                    list.append(camera)
                }
                mutes[mode] = list
                Task { await save() }
            }
        )
    }

    private func save() async {
        syncState = .saving
        do {
            try await appState.saveHouseModeMap(mutes)
            syncState = .synced
        } catch {
            syncState = .failed
        }
    }

    private func reset() async {
        syncState = .saving
        do {
            try await appState.saveHouseModeMap([:], reset: true)
            seeded = false
            seedIfNeeded()
            syncState = .synced
        } catch {
            syncState = .failed
        }
    }

    private func titleize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
