# ApexSight — Reconnaissance Report (Phase 1)

_Date: 2026-06-16 · against `FRIGATE_APP_AUDIT.md`. Authored from a Linux checkout
(no Xcode), so build/Instruments/device/CarPlay-sim verification is the Mac owner's
step; everything here is from reading the code + verifying endpoints against
Frigate's live `dev` source._

## 1. Project shape

- **XcodeGen project** (`native-ios/project.yml`), **min iOS 17.0**, Swift (no
  Swift-6 language mode flag set).
- **Targets** (4): `ApexSightNative` (app), `ApexSightWidgets` (WidgetKit +
  Controls app-extension), `ApexSightNotificationService` (NSE), `ApexSightWatch`
  (watchOS app). App Intents live **in-app + a shared module**, not a separate
  extension. CarPlay is a **scene delegate** on the main app
  (`CarPlaySceneDelegate`), not a separate target.
- **Dependencies: none.** Pure SwiftUI + AVFoundation + WidgetKit + ActivityKit +
  AppIntents + WatchConnectivity. **No WebRTC SDK, no MobileVLCKit/jsmpeg** — see
  §6.
- **App Group** `group.com.brandontoth.apexsight`; bundle id
  `com.brandontoth.apexsight.native`.
- **Push relay** (FastAPI) + **HA bridge** live in-repo: `homeassistant-addon/
  apexsight-push/` (canonical, deployed as the HA add-on) and `push-relay/` (older
  standalone copy).

## 2. Architecture map

- **MVVM-ish, single source of truth.** `AppState` (`@MainActor ObservableObject`)
  owns cameras, events, reviews, labels, sub-labels, stats, capabilities, deep
  links, arm/snooze sync, plus the shared `NotificationPreferencesStore` /
  `NotificationTriggerStore`. Views read it via `@EnvironmentObject`.
- **Concurrency:** async/await throughout; UI state `@MainActor`; networking +
  image decode off-main. Real-time via a `URLSessionWebSocketTask` event stream
  (`FrigateEventStream`) with a 15 s foreground poller fallback (proxies that drop
  `/ws`).
- **Networking:** one typed value-type client (`FrigateClient`) — central base
  URL, bearer+cookie auth, `validate()` status gate. See §3.
- **Persistence/caching:** Keychain (sessions), App Group `UserDefaults`
  (arm/snooze, prefs, widget payloads), `ImageCache` (in-memory) + `RemoteImage`
  ImageIO downsampling.

## 3. Frigate client endpoint map (verified vs Frigate `dev`)

| App call | Endpoint | Status |
|---|---|---|
| `login` | `POST /api/login {user,password}` + Set-Cookie/jar fallback | ✓ |
| `config` / `cameras` | `GET /api/config` | ✓ |
| `events(...)` | `GET /api/events` (singular `camera/label/zone/sub_label` — accepted via Frigate back-compat) | ✓ |
| `semanticSearch` | `GET /api/events/search?query&search_type=thumbnail,description` + plural filters | ✓ (broadened) |
| `findSimilar` | `GET /api/events/search?event_id&search_type=similarity` | ✓ (fixed) |
| `reviews(...)` | `GET /api/review` (`severity/reviewed/before/limit`) | ✓ |
| `markReviewsViewed` | `POST /api/reviews/viewed {ids,reviewed:true}` | ✓ (fixed) |
| `labels`/`subLabels`/plates | `GET /api/labels`, `/api/sub_labels`, `/api/recognized_license_plates` | ✓ |
| event media | `/api/events/{id}/{thumbnail.jpg,snapshot.jpg,clip.mp4,preview.gif}` | ✓ |
| live | `GET /api/go2rtc/api/stream.m3u8?src&mp4` (HLS via go2rtc) | ✓ (see §6) |
| snapshots | `/api/{camera}/latest.jpg` | ✓ |
| recordings VOD | `/vod/{camera}/start/{s}/end/{e}/master.m3u8`, `/vod/event/{id}/master.m3u8` | ✓ |
| faces (0.16+) | `/api/faces`, `…/create`, `…/train/{name}/classify`, `…/delete`, `…/rename` | ✓ |
| PTZ move | `GET /api/{camera}/ptz?action=` | 🟠 **not a real Frigate HTTP route** — only `/ptz/info` exists; PTZ is MQTT-only |

Auth is centralized (bearer + `frigate_token` cookie + cookie-jar seeding for
AVPlayer/WebSocket). 401 → `reauthenticate()` is wired in the live player and image
loader. No force-unwraps on decode; `FrigateEvent` handles `end_time: null` and
`sub_label` string-or-array variance.

## 4. Surface & control inventory (high level)

- **Cameras:** live wall (LazyVStack), per-camera live (HLS, mute, fullscreen,
  snapshot, PTZ when capable), groups (now editable).
- **Review:** alert/detection severity, label + sub-label rows, animated preview,
  mark-viewed (round-trips with `reviewed:true`), bulk mark-all, tap → clip at
  timestamp.
- **Explore:** browse grouped by object (sub-labels first), unified semantic +
  on-device relevance fallback, filters (camera/label/sub-label/zone/date/plate),
  find-similar, Smart Albums, Ask.
- **Activity / Settings:** recap, plates, faces, triggers, servers, push companion,
  alert style, system health.
- **Cross-surface:** widgets (Home + Lock Screen accessory + Controls), Live
  Activity / Dynamic Island, CarPlay (snapshots + alerts), Watch, App Intents
  (Spotlight, Siri, Control Center, Focus filter, Arm/Disarm).

## 5. Cross-surface data inventory

Single in-app source of truth is `AppState`. Extensions read the **App Group**
container (latest-alert payload, arm/snooze, prefs) and **Keychain** (session) —
they do not fork networking, except the NSE which authenticates snapshot/GIF
downloads using the mirrored base-URL+token. Arm/Snooze is shared via App Group
and now also mirrored to the relay (§ relay gate). Label/sub-label display flows
from one `NotificationCopy`/`displayLabel` path.

## 6. Known platform-limited items (honest, per brief §0)

- **Live = HLS via go2rtc → AVPlayer, not WebRTC.** Works through the user's
  HTTPS/Cloudflare-tunnelled auth port with no extra ports, and falls back
  main→sub stream after 3 failures. True WebRTC (<200 ms) would require adding a
  WebRTC SDK dependency + go2rtc 8555 reachability — a deliberate future upgrade,
  not a bug. Current first-frame is "fast enough" but not sub-second.
- **CarPlay = snapshots + alerts list only.** Correct per Apple; no live video on
  CarPlay is possible.
- **Notifications = APNs relay** (HA add-on bridge → FastAPI relay → APNs) with a
  local/background fallback. This is the recommended model.
- **PTZ** control can't work over pure HTTP (Frigate exposes PTZ via MQTT). Gated
  to PTZ-capable cameras so it's normally hidden.
- **Relay gate lag:** Disarm/Snooze made from a widget/Siri while the app is fully
  closed reach the relay on next app foreground (the app is the only process with
  the relay URL + pairing code).
