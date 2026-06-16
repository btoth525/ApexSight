import WidgetKit

/// One place to nudge every passive surface after arm/snooze state changes, so the
/// home/Lock-Screen widgets and the Control Center arm toggle reflect the new state
/// immediately — no matter which process made the change (app, App Intent, widget,
/// Siri, or the Watch handler). Called from the `ArmStateStore.mode` setter and the
/// `GlobalSnooze` mutators, which every writer funnels through.
enum ApexSurfaceRefresh {
    static let armControlKind = "com.brandontoth.apexsight.control.arm"

    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: armControlKind)
        }
        #endif
    }
}
