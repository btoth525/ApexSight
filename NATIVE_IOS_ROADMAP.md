# ApexSight Native iOS Roadmap

Goal: make ApexSight feel like a first-class SwiftUI-style Frigate client while keeping Frigate server-side compatible and unmodified.

## Already Started

- Native glass home screen with camera grid, latest snapshots, recent alerts, pull-to-refresh, and Frigate Web fallback.
- Native event filters by camera, object, and confidence.
- Native event detail view with snapshot, zones, confidence, clip action, and in-app Frigate review handoff.
- Local native notifications from Frigate events with basic cooldown.
- Production direction focuses on stock-Frigate native alerts only — zero server modifications.
- Real SwiftUI app foundation under `native-ios/` with native login, dashboard, event details, authenticated media loading, clip playback, system health, Keychain session storage, and XcodeGen project config.

## Shipped (native-ios)

- Real-time alerts via Frigate's stock `/ws` WebSocket: live review/event/stats updates, in-app banner, connection indicator, auto-reconnect.
- Background alerts via BGAppRefreshTask with app-group dedupe (LastSeenStore) and rich local notifications.
- Optional instant-push companion (clearly optional): in-app APNs registration + copyable device token; standalone notifier documented in `frigate-integration/` (no committed secrets).
- Picture-in-Picture, multi-camera live wall (1–4 up), camera groups & saved grids.
- iPad sidebar layout + landscape camera wall.
- Live Activities (Lock Screen + Dynamic Island) for in-progress alert incidents.
- Face & license-plate recognition surfaced in rows, detail, notifications, and search (Frigate 0.15+).
- Per-camera notification snooze, quiet hours, per-object/zone toggles.

## Native SwiftUI Build Step

The SwiftUI app must be built on macOS with Xcode:

```sh
brew install xcodegen
cd native-ios
xcodegen generate
open ApexSightNative.xcodeproj
```

Windows can edit the Swift files, but cannot compile or run the iOS target.

## Next Native App Features

Competitive baseline researched: Verkada Command, Scrypted NVR, CrowsEye, Viewu, Viewer for Frigate, Fregata, Frigate PWA/WebPush, and Home Assistant notification blueprints. ApexSight should match the basics, then beat them with better native notification flows, cleaner diagnostics, and no required Frigate server patch. Details live in `COMPETITIVE_RESEARCH.md` and `NATIVE_DESIGN_DIRECTION.md`.

1. Persistent notification controls
   - Per-camera toggles.
   - Per-object toggles.
   - Per-zone toggles.
   - Quiet hours.
   - Cooldown per camera/object.
   - Critical-alert mode for high-priority person/package alerts after explicit opt-in.

2. Real-time MQTT mode
   - Optional MQTT host/port/WebSocket setup.
   - Subscribe to `frigate/events` without modifying Frigate.
   - Cloudflare Access headers where the broker is tunneled.
   - Fall back to Frigate WebSocket when MQTT is not configured.

3. Rich iOS notifications
   - Native Notification Service Extension.
   - Download Frigate snapshots into notification attachments.
   - Actions: view event, snooze camera, open live view, mark reviewed.
   - Requires Expo prebuild/custom native target or moving the app into a fuller native iOS workspace.

4. Widgets and Live Activities
   - Lock Screen widget for latest camera snapshot.
   - Home Screen widget for selected camera/event feed.
   - Live Activity for an urgent alert window or active incident review.
   - Requires native WidgetKit/ActivityKit targets.

5. Native media review
   - In-app authenticated clip playback.
   - Scrubbable timeline.
   - Snapshot sharing/export.
   - Event retain/unretain and false-positive actions where supported by the Frigate API.

6. Diagnostics
   - Frigate connectivity status.
   - WebSocket/MQTT state.
   - Push notification permission and delivery status.
   - Copyable debug bundle for support.
   - Fregata-style health cards: CPU, RAM, detector latency, uptime, active cameras, disk usage, process status, and recent errors.

7. Multi-server and smart network switching
   - Store multiple Frigate homes/sites.
   - Internal and external URL per server.
   - Automatic LAN detection and fastest-route selection.
   - Cloudflare Access service-token and browser-login options.

8. Camera power tools
   - PTZ controls when `/api/:camera_name/ptz/info` reports support.
   - Custom camera groups and manual ordering.
   - Picture-in-Picture live camera mode.
   - 360 camera dewarping presets where metadata is available.

9. Recording review
   - Calendar/day scrubber.
   - Native HLS playback for iOS recording ranges.
   - Synchronized multi-camera scrubbing inspired by Fregata's recording/review UI.
   - Pinch-to-zoom snapshots and clips.
   - Save snapshots and clips to Photos with explicit permission.

10. Event management
   - Retain/unretain events.
   - Delete events.
   - Mark false positives.
   - Export clips.
   - Fast day, camera, zone, object, and score filters.

11. Apple ecosystem expansion
   - Keep iOS as the core app.
   - Optional macOS menu-bar companion later for users running stock Frigate or Fregata.
   - Quick actions: open web UI, view health, restart optional local helper, copy diagnostics.
   - Stay client-side unless the user explicitly installs a helper.

12. Detection and camera tuning
   - Read Frigate config and expose zones/masks/objects in a native editor where the API safely allows it.
   - Per-object threshold review.
   - Camera capability cards: resolution, FPS, audio, PTZ, go2rtc/live modes.
   - Never write config changes without a preview and explicit confirmation.

13. Verkada/Scrypted-inspired command experience
   - Command dashboard: live cameras, alerts, health, local/remote mode.
   - Saved camera grids and camera groups.
   - One-thumb recording timeline.
   - Incident bundles for related events, snapshots, and clips.
   - Smart search across labels, zones, cameras, and time.
   - Stream resilience with WebRTC/HLS/latest-frame fallback.

14. Scrypted-inspired reliability layer
   - Camera capability registry: PTZ, audio, WebRTC, HLS, latest frame, snapshots, clips, zones, and stats.
   - Per-camera stream strategy: LAN WebRTC, remote HLS, low-bandwidth latest-frame mode.
   - Warm-start important streams before opening live view when the user marks them as priority.
   - Native diagnostics wizard: server, auth, cameras, snapshots, clips, WebRTC, MQTT, and notifications.
   - Test notification button with rich snapshot preview.
   - Home Assistant helper export for object-class sensors and selected alert events.

## Server Compatibility Rule

ApexSight should work with stock Frigate APIs first: HTTP API, event media endpoints, live stream endpoints, WebSocket/MQTT events, and authentication cookies/tokens. Any optional companion service must be clearly optional and not required for normal Frigate users.

Frigate endpoint coverage and native notification copy rules live in `FRIGATE_API_COVERAGE.md`.
