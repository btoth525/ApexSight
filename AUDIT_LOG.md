# ApexSight — Audit Log

Severity: 🔴 broken · 🟠 fragile · 🟡 polish. Verified against Frigate `dev` source
and code review. Build/device verification is the Mac owner's step (no Xcode in the
audit environment).

## 2026-06-16

### Frigate API correctness
- 🔴 **Find Similar** called `/api/events?similarity_event_id=` (param no longer
  exists) → **Fixed:** `/api/events/search?event_id&search_type=similarity`.
  Verified the search handler reads `event_id` + `search_type=similarity`.
- 🔴 **Mark reviewed** posted `{ids}` only; current Frigate's
  `ReviewModifyMultipleBody` requires `reviewed`, so it was a silent no-op (root
  cause of "marked items come back"). **Fixed:** `{ids, reviewed:true}`. Verified
  handler sets `has_been_reviewed = body.reviewed`.
- 🟠 **Login** missed the JWT when Frigate returns an empty 200 + Set-Cookie that
  URLSession moves to the jar. **Fixed:** cookie-jar fallback.
- 🟡 **Semantic search** used the server default `search_type=thumbnail`. **Fixed:**
  request `thumbnail,description` so Explore also matches GenAI descriptions.
- 🟠 **PTZ move** uses `GET /api/{camera}/ptz?action=` which is not a Frigate HTTP
  route (PTZ is MQTT-only; only `/ptz/info` exists). **Logged** — gated to PTZ
  cameras so usually hidden; needs MQTT or removal to be truly functional.
- ✓ Confirmed correct (no change): events (singular params via back-compat),
  review, media (`preview.gif`, `snapshot.jpg`, `clip.mp4`, `thumbnail.{ext}`,
  `latest.{ext}`), VOD `master.m3u8`, faces, labels/sub_labels/plates.

### Explore search
- 🔴 **"kid on a bike" returned nothing.** Fallback parsed one label and queried
  only it; "kid" wasn't mapped to person. **Fixed:** expanded person synonyms,
  added `AskParser.impliedLabels(in:)`, and a real on-device relevance fallback
  (ranks a broad recent set by label/sub-label/face/plate/camera/zone match, no
  time cap) when semantic search is off/empty.
- 🟡 Browse list no longer blanks on a transient fetch error.

### Notifications / relay (cross-surface "single source of truth")
- 🔴 **Triggers feature was dead** — `shouldDeliverViaTrigger` never called; the
  per-event editor used a throwaway store. **Fixed:** one shared
  `NotificationTriggerStore` on `AppState`; both editors use it; both local
  delivery paths now apply triggers as ADDITIVE allow-rules (can re-open a muted
  combo / quiet hours; never override Disarm/Snooze; shared cooldown).
- 🔴 **Disarm/Snooze didn't stop app-closed pushes** (relay delivered everything
  the bridge forwarded). **Fixed:** relay `POST /v1/gate` + `/v1/notify` gate;
  iOS `RelayClient.syncGate` + `AppState.syncRelayGateIfChanged()`. HA add-on
  → 1.2.0. (Limitation: closed-app changes sync on next foreground.)

### Stability / lifecycle
- 🟠 Recording context player only paused on disappear → leaked AVPlayer + loop
  observer. **Fixed:** `stop()`.
- 🟠 Live HLS KVO callbacks could fire after teardown. **Fixed:** `isStopped`
  guards in the status/timeControl observers.
- 🟡 GIF previews weren't animating (single-frame decode). **Fixed:** preserve all
  frames + delays in `RemoteImage.downsample`.
- 🟡 Review/widget didn't refresh on sub-label-only changes (id-only diff).
  **Fixed:** content-signature diff.

### UI correctness
- 🟠 Camera groups couldn't be edited (always created new). **Fixed:** tap-to-edit
  + in-place update.
- 🟠 Deleting the active server stranded a blank pushed screen. **Fixed:** dismiss
  before sign-out.
- 🟡 Daily Recap didn't request notification permission on enable. **Fixed.**
- 🟡 `RecapSettings.todayKey` now locale-stable (en_US_POSIX / Gregorian).
- 🟡 Removed a redundant reload in plate Import.

## 2026-06-16 — Round 2 (6 parallel surface audits, triaged)

### Cameras / Live
- 🔴 Live AVPlayers kept decoding HLS in the background (onDisappear doesn't fire
  on backgrounding). **Fixed:** HLSLiveModel pauses on `didEnterBackground`,
  reconnects fresh on `willEnterForeground`.

### Review
- 🟠 Marking a detection viewed from the detail screen left it in the Detections
  list (that list is owned by the tab, not pruned by AppState). **Fixed:** filter
  the tab's lists by `AppState.locallyViewedIDs` (now published).
- 🟠 Detections never re-polled (one-shot). **Fixed:** 15s re-poll while the
  Detections filter is active; cancels on filter change/exit, skips viewed ids.
- 🟡 Mark-all dialog showed a misleading loaded-count. **Fixed:** copy now states
  it marks the whole backlog. Rows show "Person — Alex" + are one VoiceOver element.

### Explore / Activity / EventDetail
- 🔴 Activity filters only searched the latest ~50 cached events → common combos
  looked empty. **Fixed:** active filters query the server (limit 300) + Clear chip.
- 🔴 "Find Similar" showed the same "needs embeddings" copy for a real fetch error.
  **Fixed:** distinct error vs empty state.
- 🟠 "Regenerate description" only re-GET the same text. **Fixed:** real
  `PUT /events/{id}/description/regenerate` (verified) + re-fetch.
- 🟠 Shared `isActing` disabled/spun all action buttons + Find-Similar double-fire.
  **Fixed:** per-action loading flags.
- 🟠 Action feedback shown in green for errors and never cleared. **Fixed:** error
  color + 3s auto-dismiss.
- 🟡 EventRow printed the recognized name twice. **Fixed:** object in title,
  sub-label/plate as chip. Explore empty state gains "Clear Filters".

### Widgets / extensions
- 🔴 Control Center arm toggle + widgets never reloaded on arm/snooze change.
  **Fixed:** ApexSurfaceRefresh.reload() from the ArmStateStore/GlobalSnooze
  chokepoints (covers app, intents, widget, Siri, Watch).
- 🟠 NSE accepted non-2xx/non-HTTP responses (could attach a proxy login page).
  **Fixed:** `?? false`. 🟠 Live Activity camera deep link now percent-encoded.
- 🟡 Watch kept showing the last household after sign-out. **Fixed:** push empty.

### Core
- 🟡 No per-request timeout (URLSession.shared 60s). **Fixed:** dedicated session
  15s/60s, no waitsForConnectivity. 🟡 Image loads reauth on 401. 🟡 Heartbeat ping
  captures self weakly. 🟡 startForegroundPolling() idempotent.

### Triaged as NOT worth changing (false-positive / debatable)
- Widget background fetch ignoring arm/snooze: a widget is a passive glance, not a
  notification — freezing it on disarm would just look stale. Left as-is.
- PTZ over HTTP: Frigate is MQTT-only; already logged (gated to PTZ cameras).
- RecordingContextPlayer marker drift, latest.jpg TTL, MJPEG O(n²), idle-cell
  snapshot promotion, token-in-app-group: noted; deferred (larger/again debatable).

## Open / deferred
- 🟠 PTZ over HTTP (needs MQTT path or hide).
- 🟡 WebRTC live (would need a WebRTC SDK; HLS is the working path today).
- 🟡 `push-relay/` standalone copy is older than the HA add-on relay (canonical);
  left as-is.
- ⏳ Not verifiable from Linux: on-device push round-trip, CarPlay sim, Instruments
  leak/memory soak, Dynamic Type/VoiceOver pass. These are the Mac owner's gates.
