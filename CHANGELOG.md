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

## Build 162
### Fixed
- **Review/Activity thumbnails no longer flicker or re-flash when you scroll.** Finished events
  and reviews now load their image once and keep it — previously the app kept re-downloading a
  settled snapshot for two minutes after the event ended, so tiles flashed every time they scrolled
  back into view. Images that are still being captured (live events) still update to the best frame,
  and a tile whose image is refreshing keeps showing the current frame instead of blanking.

## Build 161
### Fixed
- **Per-camera notification mute now applies when the app is closed.** The app now syncs which
  cameras you've turned notifications OFF for to the push relay, so a disabled camera stays quiet
  even on remote pushes — previously the per-camera toggle only silenced foreground alerts.
  (Requires the paired ApexSight Push add-on 1.4.2, which enforces it and also fixes the
  notification image + a dropped-alert-on-escalation bug.)

## Build 160
### Fixed
- **Review snapshots now show the right moment.** The app was picking the earliest detection in a
  review, but Frigate re-links long-running (parked-car) tracks into new reviews, so that was often
  the wrong frame. It now uses the review's own thumbnail moment to choose the image (and the same
  fix applies to the notification GIF/snapshot).
- **High-resolution review images restored** — the thumbnail fallback and the widget/CarPlay image
  no longer drop to the small canonical review thumbnail.
- **Activity feed no longer jumps** when a new event arrives — the list now animates the insert
  instead of jolting everything down a row (respects Reduce Motion).

## Build 159
### Fixed
- **Live camera no longer black-flashes after recovering from a stall** — a stalled stream that
  rebuffered on its own could still get torn down and rebuilt a few seconds later; the stale
  reconnect is now correctly cancelled.
- **Incident reels stop when the app backgrounds** — the stitched-clip player no longer keeps
  playing audio behind the lock screen; it pauses on background and resumes on return.
- **Two-way talk releases the mic immediately if the connection drops** mid-talk (previously the
  mic stayed live until you released the button).
- **Retry on an offline camera restores the sub-second live path**, not just standard playback.
### Changed
- Clearer PTZ error feedback; login screen animations respect Reduce Motion.

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
