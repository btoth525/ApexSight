# ApexSight Native iOS

This is the start of a real SwiftUI version of ApexSight. The goal is to become a first-class native Frigate client while keeping the existing Expo app available during the migration.

## Why This Exists

Expo/React Native is useful for fast iteration, but the best iOS experience for ApexSight needs native targets:

- SwiftUI screens and Apple glass materials.
- URLSession and AVKit-based Frigate media.
- WidgetKit camera widgets.
- Notification Service Extension for rich snapshots.
- ActivityKit for live alert and incident status.
- Cleaner iPad and landscape behavior.

## Project Generation

This folder uses XcodeGen so the project file does not need to be hand-maintained.

On a Mac:

```sh
brew install xcodegen
cd native-ios
xcodegen generate
open ApexSightNative.xcodeproj
```

## Current Native Foundation

- Frigate login using `/api/login`.
- Secure-ish session storage through Keychain.
- Camera list from `/api/config`.
- Latest camera stills through `/api/:camera/latest.jpg`.
- Recent events from `/api/events`.
- Event detail snapshots through `/api/events/:id/snapshot.jpg`.
- Event playback through Frigate HLS at `/vod/event/:event_id/master.m3u8`.
- Review items through `/api/review`.
- Native review detail with HLS playback, timeline metadata, objects/zones/audio tags, and confirmed `POST /api/reviews/viewed` handling.
- Labels, sub-labels, logs, recordings, and go2rtc stream discovery.
- Manual diagnostics for snapshot, recording, and PTZ capability probes.
- System stats from `/api/stats`.
- WidgetKit latest-camera widget backed by an app-group snapshot cache.
- Notification Service Extension scaffold for rich snapshot attachments from Frigate alert payloads.
- Notification action categories for open, reviewed, and snooze actions.
- Native `apex://` links for review, event, and camera routing.
- Apple glass visual system using SwiftUI materials.

## Device Validation Checklist

Run these on a Mac before treating the native app as shippable:

```sh
cd native-ios
xcodegen generate
xcodebuild -project ApexSightNative.xcodeproj -scheme ApexSightNative -destination 'generic/platform=iOS' build
```

Then test on a real iPhone:

- Sign in to a stock Frigate server.
- Confirm dashboard refresh loads cameras, review items, events, labels, stats, and logs.
- Open a review item and confirm HLS playback, tags, and Mark Reviewed work.
- Open an event and confirm HLS playback works.
- Add the camera widget and confirm the cached latest snapshot appears after opening the app.
- Send a test notification and confirm actions render.
- Test a push payload with `snapshot_url`, `review_id`, and `apex_url` to verify rich media and routing.
- Run System Health diagnostics and confirm recordings/PTZ/WebRTC capability cards behave without freezing the dashboard.

## Competitive Target

Research notes are tracked in `../COMPETITIVE_RESEARCH.md`. The native app should take the best client ideas from CrowsEye, Viewu, and Viewer for Frigate, the best Apple-local ideas from Fregata, and the reliability/product architecture lessons from Scrypted: privacy-first posture, strong diagnostics, stream preflight, polished review/timeline UX, and no required cloud account.

Frigate API coverage is tracked in `../FRIGATE_API_COVERAGE.md`.

## Migration Rule

Keep the native app compatible with stock Frigate first. Camera-specific helpers should be optional and should never be required for normal Frigate users.
