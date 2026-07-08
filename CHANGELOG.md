# Changelog

All notable changes to ApexSight (the native iOS client for Frigate NVR).

The project follows a single rolling `CFBundleVersion` (build number) tracked in
`native-ios/project.yml`. Marketing version is `1.0.0`.

## [Unreleased]

### Planned
- Full-event notification GIF via a follow-up "final update" push (collapse-id).
- Stability hardening: automatic re-login on expired sessions, safer data refresh,
  reliable Keychain writes, notification-extension download timeout.
- Reliability: relay/bridge retry, smarter alert de-duplication, wider background-refresh coverage.
- Polish: loading skeletons, media retry buttons, persisted filters, accessibility & form validation.
- New surfaces: Apple Watch companion, Siri Shortcuts / App Intents, CarPlay.

### Removed
- Legacy Expo / React Native prototype (`app/`, `components/`, `stores/`, `hooks/`,
  `utils/`, and the Expo/Metro/NativeWind tooling). The native SwiftUI app fully
  supersedes it; the repository is now Swift + the Python push companions only.

## Build 158
### Fixed
- **Live cameras no longer get stuck in low quality.** Removed a bug that could permanently pin a
  camera to Frigate's low-resolution detect stream for the rest of a session after a single slow
  start — every reopen now re-attempts full-quality HLS and self-heals.
- **Doorbell and movie room now show full resolution.** Root cause was server-side: several go2rtc
  streams were raw RTSP passthrough that iOS's video decoder connects to but can't render. The
  Frigate/go2rtc streams were re-wrapped through ffmpeg (short-GOP NVENC re-encode for the doorbell's
  long keyframe interval; lightweight repackage for the rest) so iOS AVPlayer decodes them at full
  quality. This also keeps the sub-second WebRTC overlay from being torn down.
- Widened the HLS→MJPEG fallback grace period to accommodate on-demand re-encoded streams that
  cold-start the first time they're watched.

_(Builds 19–157 tracked in git history and the project memory; this entry resumes the changelog.)_

## Build 18
- Synced `project.yml` build number for TestFlight.

## Build 16
- Instant-push rework: baked relay URL, always-on status indicator, real Test button.
- ApexSight Push delivered as an all-in-one Home Assistant OS add-on.

## Build 15
- GenAI event descriptions (edit & regenerate).
- Recording history scrubber with event ticks.
- "Find similar" semantic search and notification triggers.
- GIF notification attachment fix.

## Build 14
- Live cameras wall that stays loaded, with drag-to-arrange.
- Redesigned Home/Lock Screen widget.
- Reliable test alert.

## Build 13
- Comprehensive bug-fix pass: real-time updates, notifications, Live Activities, deep links.
