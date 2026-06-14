# Frigate API Coverage Plan

Goal: ApexSight should take advantage of the stock Frigate server before adding any optional helper. This keeps the app useful to every Frigate user and avoids server-side patches.

## Native App Coverage

| Frigate Area | Endpoint / Topic | ApexSight Use |
| --- | --- | --- |
| Auth | `POST /api/login` | Native sign-in and authenticated media |
| Config | `GET /api/config` | Camera list, zones, tracked objects, capability cards |
| Health | `GET /api/` | Server reachability and diagnostics |
| Version | `GET /api/version` | Compatibility display |
| Stats | `GET /api/stats`, MQTT `frigate/stats` | System health, detector speed, camera FPS |
| Logs | `GET /api/logs/:service` | Diagnostics and support bundle |
| Labels | `GET /api/labels`, `GET /api/sub_labels` | Filters, search, notification rules |
| Events | `GET /api/events`, `GET /api/events/:id` | Activity feed and event detail |
| Event Media | `GET /api/events/:id/snapshot.jpg`, `GET /vod/event/:event_id/master.m3u8` | iOS-friendly playback, details, sharing/export |
| Review | `GET /api/review`, `POST /api/reviews/viewed`, MQTT `frigate/reviews` | Primary alert feed, incident workflow, mark-reviewed actions |
| Latest Frame | `GET /api/:camera/latest.jpg` | Camera grid thumbnails and widgets |
| Recordings | `GET /api/:camera/recordings?after=:after&end=:end` | Timeline and calendar review |
| Recording Media | `GET /api/:camera/start/:start/end/:end/clip.mp4`, HLS VOD routes | Clip playback/export |
| go2rtc | `GET /api/go2rtc/streams` | WebRTC/live capability detection |
| PTZ | `GET /api/:camera/ptz/info` | Show PTZ controls only when supported |
| Notifications | Frigate WebPush docs, MQTT notification state | Native notification settings and diagnostics |
| Enrichments | MQTT classification/LPR/trigger messages | Future smart search and richer alert text |

## Native Notification Voice

Notifications should be glanceable, friendly, and useful:

- `🧍 Person detected`
- `📦 Package detected`
- `🚗 Vehicle in Driveway`
- `🔎 Plate recognized`
- Body format: `Camera • confidence • zone`
- Examples:
  - `Front Porch • 94% confidence • Zone: Walkway`
  - `Driveway • Alert • Zone: Front Yard`

## Product Rules

- Use `frigate/reviews` as the preferred alert stream when MQTT is configured because it groups related detections into review items.
- Fall back to Frigate WebSocket or `/api/events` polling when MQTT is not configured.
- Fetch snapshots/clips directly from stock Frigate media endpoints for rich notifications and event details.
- Use the native Notification Service Extension to attach `snapshot_url`, `image_url`, or `thumbnail_url` media from push payloads.
- Use the WidgetKit app-group cache for latest-frame widgets so the Home Screen stays fast and private.
- Route notification/widget taps through `apex://review?id=...`, `apex://event?id=...`, and `apex://camera?name=...`.
- Never require Frigate server patches for normal use.
- Any write operation, such as delete/retain/config changes/restart, must show a clear confirmation first.
