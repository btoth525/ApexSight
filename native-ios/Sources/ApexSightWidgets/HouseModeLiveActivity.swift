import ActivityKit
import WidgetKit
import SwiftUI

// Lock Screen + Dynamic Island rendering of the house-mode arm banner. During the exit delay it
// shows a live countdown ("Arming Away · 0:27") with a Disarm button; once the countdown ends it
// reads "Armed Away". Tapping / Disarm opens the app to House Mode (Face ID + code live there).

private func isArming(_ state: HouseModeActivityAttributes.ContentState) -> Bool {
    state.endsAt > Date().timeIntervalSince1970
}
private func endDate(_ state: HouseModeActivityAttributes.ContentState) -> Date {
    Date(timeIntervalSince1970: state.endsAt)
}
private func headline(_ state: HouseModeActivityAttributes.ContentState) -> String {
    let title = SharedHouseMode.title(state.mode)
    return isArming(state) ? "Arming \(title)" : "Armed \(title)"
}

struct HouseModeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HouseModeActivityAttributes.self) { context in
            HouseModeLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let color = modeColor(state.mode)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: SharedHouseMode.symbol(state.mode))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if isArming(state) {
                        Text(timerInterval: Date()...endDate(state), countsDown: true)
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(color)
                            .frame(width: 62)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(color).font(.title2)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(headline(state)).font(.headline)
                        if !state.by.isEmpty {
                            Text("by \(state.by)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Link(destination: URL(string: "apex://house")!) {
                        Label(isArming(state) ? "Disarm / Cancel" : "Disarm",
                              systemImage: "lock.open.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .tint(.white)
                }
            } compactLeading: {
                Image(systemName: SharedHouseMode.symbol(state.mode)).foregroundStyle(color)
            } compactTrailing: {
                if isArming(state) {
                    Text(timerInterval: Date()...endDate(state), countsDown: true)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(color)
                        .frame(width: 34)
                } else {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(color)
                }
            } minimal: {
                Image(systemName: SharedHouseMode.symbol(state.mode)).foregroundStyle(color)
            }
            .widgetURL(URL(string: "apex://house"))
        }
    }
}

private struct HouseModeLockScreenView: View {
    let state: HouseModeActivityAttributes.ContentState

    var body: some View {
        let color = modeColor(state.mode)
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.22)).frame(width: 46, height: 46)
                Image(systemName: SharedHouseMode.symbol(state.mode))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(state)).font(.headline).foregroundStyle(.white)
                if !state.by.isEmpty {
                    Text("by \(state.by)").font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                } else {
                    Text(SharedHouseMode.subtitle(state.mode)).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            if isArming(state) {
                VStack(spacing: 1) {
                    Text(timerInterval: Date()...endDate(state), countsDown: true)
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(color)
                        .frame(width: 74)
                        .multilineTextAlignment(.trailing)
                    Link(destination: URL(string: "apex://house")!) {
                        Text("Disarm").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    }
                }
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.largeTitle)
                    .foregroundStyle(color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
