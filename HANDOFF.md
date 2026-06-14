# ApexSight Handoff

## Current Direction

ApexSight is moving to a production-ready, native SwiftUI Frigate client with an Apple glass command-center feel. The old experimental phone-call doorbell path has been retired from the app direction.

## Product Goals

- Native SwiftUI iOS app under `native-ios/`.
- Stock Frigate compatibility first: HTTP API, media endpoints, WebSocket/MQTT events, and authentication.
- Beautiful command dashboard inspired by high-end NVR apps without copying their branding.
- Rich notifications, widgets, timeline/review, diagnostics, camera capability cards, and polished Frigate media review.
- No hard-coded private tokens, APNs keys, device tokens, or camera passwords in the repo.

## Current Native App Foundation

- `native-ios/` contains the SwiftUI app scaffold.
- XcodeGen config is in `native-ios/project.yml`.
- SwiftUI screens include login, dashboard, camera cards, event rows/details, review rows/details, authenticated remote images, HLS playback, notification settings, and system health.
- Review workflow uses stock Frigate APIs: `GET /api/review`, HLS VOD playback, and confirmed `POST /api/reviews/viewed` for mark-reviewed.
- WidgetKit latest-camera widget reads a cached snapshot from the shared app-group container.
- Notification Service Extension can attach rich media from `snapshot_url`, `image_url`, or `thumbnail_url`.
- Notification categories are registered for open, reviewed, and snooze actions.
- Native `apex://review`, `apex://event`, and `apex://camera` deep links are wired for notification/widget routing.
- Dashboard refresh is kept light; heavier snapshot/recording/PTZ capability checks run from System Health diagnostics.
- Build requires macOS + Xcode:

```sh
brew install xcodegen
cd native-ios
xcodegen generate
open ApexSightNative.xcodeproj
```

## Latest Validation

- `npx tsc --noEmit` passed on Windows.
- `npx expo install --check` passed.
- `npx expo export --platform ios --output-dir .expo-export-check` passed, and the temporary export folder was removed.
- `npx expo-doctor --verbose` passed 16 checks; the Expo API-backed native module compatibility check failed with `TypeError: fetch failed`.
- Swift/XcodeGen are not installed on this Windows machine, so the native Swift targets still need Mac validation:

```sh
cd native-ios
xcodegen generate
xcodebuild -project ApexSightNative.xcodeproj -scheme ApexSightNative -destination 'generic/platform=iOS' build
```

## Retired

- Incoming phone-call-style doorbell alerts.
- Dedicated telephony push registration.
- Camera-specific two-way audio proxy experiments.
- Home Assistant APNs wrapper scripts.

Those experiments should not be reintroduced unless they become a clearly optional separate helper with a security review.
