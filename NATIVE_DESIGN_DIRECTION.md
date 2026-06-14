# ApexSight Native Design Direction

Goal: ApexSight should feel like an Apple-native command center for Frigate: refined like Verkada Command, fast and practical like Scrypted NVR, but original to ApexSight.

## Visual Personality

- Enterprise calm: dense information, clear hierarchy, no decorative clutter.
- Apple-native glass: SwiftUI materials, crisp iconography, subtle depth, dark-first.
- Operational speed: the first screen must answer what is live, what needs attention, and whether the system is healthy.
- Trustworthy security feel: local-first, privacy-forward, no cloud-account assumptions.

## First Screen

The first screen should be a command dashboard:

- Top status strip: live cameras, active alerts, health, local/remote mode.
- Camera grid: adaptive tiles with live/latest preview, recording state, resolution/FPS when available, current detections.
- Review feed: incidents/events with camera, object, confidence, time, zones.
- Fast filters: camera, object, zone, date, confidence.
- System access: health diagnostics one tap away.

## Camera View

Inspired by Verkada and Scrypted patterns:

- Large live view first.
- Timeline/review drawer that can slide over the lower half of the video.
- Quick actions: snapshot, clip, share/export, PiP, fullscreen, open in Frigate web.
- PTZ strip when supported.
- Digital zoom and pinch-to-zoom.
- Portrait camera handling without hiding the timeline.

## Review And Search

The review flow should become one of ApexSight's strongest features:

- Scrypted-style mobile timeline that is easy to scrub with one thumb.
- Verkada-style fleet search where Frigate data allows it: people, vehicles, packages, zones, cameras, time ranges.
- Incident bundles: save related clips/snapshots and add notes locally.
- Export/share flow for clips and snapshots.

## Notifications

- Rich snapshot notifications.
- Critical notifications for high-priority person/package alerts after explicit user opt-in.
- Per-camera, per-object, per-zone schedules.
- Snooze controls from notification actions.
- Test notification button and diagnostics.

## Reliability UX

Scrypted's repo treats diagnostics and stream reliability as first-class product surfaces. ApexSight should do the same:

- Camera capability cards instead of hidden assumptions.
- Clear stream path labels: WebRTC, HLS, latest frame, or Frigate web fallback.
- Preflight checks before critical live views.
- Actionable diagnostics: what failed, why it matters, and the next fix.
- Test buttons for notifications, snapshots, clips, MQTT, and live stream paths.

## Do Not Copy

Do not copy Verkada or Scrypted branding, icons, layout screenshots, color system, or wording. Use their product patterns as references and build an ApexSight-native interface around Frigate's API.
