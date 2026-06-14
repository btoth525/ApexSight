# ApexSight Competitive Research

This file tracks useful ideas from other Frigate and NVR apps so ApexSight can become a better native Apple client without copying code or depending on Frigate server modifications.

## CrowsEye

Useful ideas:

- Native iPhone/iPad Frigate client.
- Push notifications with per-camera controls.
- Multi-server support.
- Automatic internal/external network switching.
- Cloudflare Zero Trust support.
- Picture-in-Picture live streams.
- Activity indicators for motion/detections.
- PTZ support.
- System monitoring.
- 360 camera support.
- Save snapshots and clips to Photos.

ApexSight should beat it with:

- Better notification actions and rich snapshots.
- Cleaner diagnostics for WebRTC, MQTT, and notification delivery.
- SwiftUI-first design instead of a wrapped web feel.

## Viewu

Useful ideas:

- SwiftUI event timeline.
- MQTT event subscription.
- Notification templates.
- Rich notification extension.
- RTSP/HLS live view options.
- Day/date filters and pinch-to-zoom media.
- Privacy-first messaging.

ApexSight should beat it with:

- Stock-Frigate-first setup.
- Better iOS-native onboarding.
- Cloudflare Access and LAN/remote switching.
- Widgets, Live Activities, and polished alert workflows.

## Viewer for Frigate

Useful ideas:

- Event list filters by camera, object, and zone.
- Snapshot and clip preview with zoom.
- Delete and retain events.
- Latest event per camera.
- Home Assistant rich-notification automation helper.
- Camera history browsing.
- Storage/system/logs.

ApexSight should beat it with:

- Native Apple glass design.
- Better iPad support.
- Rich iOS notification extension.
- More dependable authenticated media playback.

## Fregata

Fregata is not an iOS client. It is a native macOS Frigate runtime/port focused on Apple Silicon performance.

Useful ideas:

- Local-first, privacy-first posture.
- Signed native Apple app experience.
- Apple Silicon performance messaging.
- Deep system metrics: CPU, RAM, detector latency, cameras active, uptime, disk usage.
- Menu-bar style quick controls for start/stop/restart/open web UI.
- Recording and review polish with synchronized multi-camera scrubbing.
- Detection tuning as a first-class experience: masks, zones, per-object thresholds.
- Hardware-aware media path: VideoToolbox, H.264/HEVC, full-resolution streams.
- Home Assistant and MQTT as core workflows.
- Strong onboarding: connect cameras, configure once, watch anywhere.

ApexSight should use this as inspiration in two ways:

- iOS app: show better Frigate health, recording review, MQTT notifications, retention controls, and local/remote connection confidence.
- Future Mac companion: optional native menu-bar companion for Frigate/Fregata/stock Frigate servers, with quick health, notifications, and deep links into camera review.

## Product Rule

ApexSight should remain compatible with stock Frigate HTTP API, WebSocket/MQTT events, and media endpoints. Any camera-specific or Home Assistant helper should be optional, clearly labeled, and not required for normal Frigate users.

## Verkada Command

Useful ideas:

- Polished command-center dashboard for live monitoring.
- All cameras visible in one fleet view.
- Camera grids for key areas and multi-location monitoring.
- Fast history/review access from a camera.
- People and vehicle search across cameras where analytics data exists.
- Incident workflow: collect footage, investigate, and report.
- Mobile app covers more than video: access control, alarms, intercoms, sensors.

ApexSight should translate this into Frigate-friendly features:

- Command-style first screen with live/alerts/health status.
- Camera groups and saved grids.
- Review bundles for related Frigate events.
- Search across object labels, zones, cameras, and time.
- Rich alert and incident workflows as ApexSight's standout security feature.

## Scrypted NVR

Useful ideas:

- Fast mobile NVR timeline.
- Smart search for recorded footage.
- Real-time alerts.
- Adaptive bitrate and robust stream handling.
- Onboard/camera AI can reduce server load.
- Smart motion/object sensors for automations.
- Notification testing, schedules, and critical notification workflows.
- Home Assistant integration.
- Plugin-style capability model: camera providers, WebRTC, MQTT, notification, object detection, diagnostics, and prebuffer/rebroadcast are separable building blocks.
- Rebroadcast/prebuffer strategy: keep selected streams warm for faster first frame, more reliable snapshots, and event lead-in.
- Multiple stream tiers: high/local, medium/remote, low/watch/analysis.
- Diagnostics as a product feature: validate system, validate camera, validate notifier, check recent motion, test notification delivery, and flag CPU-only detection/performance issues.
- Smart motion and occupancy sensors: turn object classes into automation-ready sensors.
- Camera-specific provider knowledge: ONVIF, RTSP, UniFi, Reolink, Tapo, Ring, Hikvision, Amcrest, DoorBird, etc.

ApexSight should translate this into Frigate-friendly features:

- Native one-thumb timeline and recording browser.
- Stream mode fallback: WebRTC, HLS, latest frame, and web fallback.
- Notification diagnostics with a test button.
- Per-camera schedules and critical alert opt-in.
- Home Assistant helper setup that stays optional.
- Camera capability registry built from Frigate config, go2rtc streams, PTZ info, latest-frame health, and stats.
- Warm-start/preflight flow for important camera streams.
- Adaptive live strategy: LAN WebRTC first, HLS/MP4 review for iOS recording, latest frame fallback, clear failure reason.
- Diagnostics wizard modeled after Scrypted's validation flow, but using stock Frigate APIs.
- Automation sensor export plan for Home Assistant: person/car/package/ring occupancy as optional HA helpers.
