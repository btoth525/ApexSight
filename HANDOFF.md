# ApexSight — Audit & Hardening Handoff

**You are picking up a mature, shipping iOS app (build 226) + its Home-Assistant push relay.**
Your job: audit, harden, and polish it toward "Apple-made-it" quality — UI, backend, correctness,
security, performance, accessibility. This doc is the mission brief + current state + the traps that
will waste your time if you don't know them. Read `CLAUDE.md` (repo root) first for the full
architecture and design system; this file assumes it.

---

## 0. TL;DR — do this first

1. Read `CLAUDE.md` (architecture, GlassTheme design system, the 5 tabs, stream architecture).
2. **Build and ship with the RELEASE SDK (Xcode 26.5)** — see §2. The wrong Xcode is refused at upload.
3. Skim §4 (what's already been done — don't redo it) and §5 (device-unverified — be careful).
4. Work the audit checklist in §6, most-impactful first. Small, isolated, bisectable commits.
5. Respect the hard rules in §3. The security constraints are non-negotiable.

---

## 1. What this app is

Native iOS client for **Frigate NVR** (self-hosted security cameras). Premium dark-glass, iOS 26/27
"Liquid Glass" design; cameras are the hero. It talks directly to Frigate over HTTP/WebRTC — no
cloud accounts. A companion **Home Assistant add-on** ("apexsight-push") is a FastAPI **relay** that
sends APNs push notifications (alerts, doorbell CallKit rings, house-mode, daily recap) so the app
gets notifications when closed.

- **App bundle**: `com.brandontoth.apexsight.native` · scheme `ApexSightNative` · deploy target iOS 17.
- **Personal app**: used only by two people (both on iOS 27). **Never submitted to the App Store** —
  distributed via TestFlight only. It still has to clear App Store Connect's upload gate, which is
  why the released SDK is mandatory (§2).

### Topology (the backend you're auditing the client against)
```
Cameras ─→ Scrypted (rebroadcast/prebuffer, holds streams hot) ─→ Frigate 0.18 (NVR: detect/record/go2rtc)
                                                                        │
   iPhone app ──HTTP/WebRTC──────────────────────────────────────────┘  (live, events, review, VOD)
        │
        └──APNs push──← Relay (FastAPI add-on in Home Assistant) ←──MQTT (frigate/reviews)── bridge
                              │
                     Home Assistant (Alarmo alarm, house mode, doorbell automation)
```
- Frigate is **0.18** — **WebRTC is the ONLY live path** (HLS `/api/go2rtc/api` route was removed).
- Live is host-only WebRTC on the LAN (fast) and STUN/TURN when away. Wall tiles use `_sub` streams.
- The relay is a **separate git repo**, cloned at `native-ios/apexsight-ha-addon/`.

---

## 2. ⚠️ BUILD & SHIP — read this or lose an hour

**Ship with the RELEASE SDK — `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(Xcode 26.5).** Apple hard-blocks a beta SDK at upload as of 2026-07-14: `ITMS-90534` went from a
warning to an outright rejection. Every build from 213 onward shipped this way; `scratchpad/ship*.sh`
already exports the right `DEVELOPER_DIR`, so copy the newest one.

The only cost is the nav-bar `toolbarMinimizeBehavior`, guarded `#if compiler(>=6.4)` so it compiles
out on 26.5 and returns automatically once an iOS 27 RC Xcode exists. Apple Intelligence vision and
NowPlaying still work — they compile against 26.5 and are runtime-gated with `@available(iOS 27, *)`.

> This section used to say the opposite ("ship the iOS 27 BETA SDK, the ITMS-90534 email is
> harmless"). That was true until the gate hardened, and following it now fails at upload every
> time. CLAUDE.md is the authority on the toolchain; this note is kept so nobody re-derives it.

```bash
# The correct toolchain:
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Xcode 26.5 / Swift 6.3.2

# Build for the simulator (zero-warning target):
cd /Users/brandon/apexsight/native-ios
xcodegen generate   # ALWAYS after any project.yml change or new file, else stale build number
xcodebuild -project ApexSightNative.xcodeproj -scheme ApexSightNative \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" -configuration Debug build \
  2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"
```
- **Sim device is `iPhone 17 Pro`** (iPhone 16 Pro no longer exists; CLAUDE.md may still say 16).
- Both toolchains still BUILD clean — the one 27-only symbol is guarded `#if compiler(>=6.4)` and
  `MainTabView.body` is split so the 6.3.2 type-checker doesn't time out — but only the release SDK
  UPLOADS. Switch back to a 27 RC Xcode the moment Apple ships one.
- **Ship pipeline**: bump `CURRENT_PROJECT_VERSION` in `project.yml` → `xcodegen generate` →
  `xcodebuild archive` (generic/platform=iOS) → `-exportArchive` with `-allowProvisioningUpdates`
  (auths off the signed-in Xcode session, no API key). Copy the newest `native-ios/scratchpad/ship*.sh` for the
  exact recipe (it already exports the right `DEVELOPER_DIR`). Never run two archives at once. Bump the build number every upload.

---

## 3. 🚨 HARD RULES — do not violate

- **CAMERAS NEVER TRIGGER THE PHYSICAL ALARM.** Frigate detections must not arm/trigger Alarmo. The
  siren is fired only by door/window/gate sensors. The house-mode filter only decides which cameras
  *notify*. Do not wire Frigate → Alarmo trigger under any circumstances.
- **Secrets never enter git.** The live Frigate config (fetched via API) contains plaintext secrets
  (MQTT password, a Gemini API key, RTSP passwords). There is a **disarm code** and a **pairing
  code** that are sensitive. Never commit any of these, never echo them into logs or this repo, never
  paste them into an external service. Edit configs in place without printing secret values.
- **Never `git add -A`** in `~/apexsight` — the tree has huge untracked dirs (node_modules, embedded
  repos) that stall it. **Stage explicit paths only.**
- **Two repos**: app at `~/apexsight` (branch `feature/ios27-platform`, remote `btoth525/ApexSight`);
  relay add-on at `native-ios/apexsight-ha-addon/` (branch `main`, remote
  `btoth525/apexsight-ha-addon`) — commit each in its own repo.
- **The `stasel/WebRTC` SwiftPM package is NOT dead — do not remove it.** It powers two-way talk and
  the sub-second live overlay. Any old note to strip it is stale.
- **End-user safety > cleverness.** This is a live home-security app. A dropped alert or a stuck-open
  mic is a real harm. Fail-open on notifications (deliver when uncertain); fail-safe on the mic/audio
  session (tear down when uncertain).
- **Every request to Frigate needs a TOTAL time cap, not just `request.timeoutInterval`.** That
  property is an *idle* timeout; Frigate streams several endpoints from an ffmpeg pipe, and a
  trickling pipe resets it forever. Use `FrigateClient.apiSession` / `downloadSession` /
  `BoundedSession` — never `URLSession.shared` (7-day resource timeout). §10 explains what this
  cost the household.

---

## 4. What was JUST done (build 202–206) — don't redo, do verify

A 24-finding audit shipped this session. Don't re-file these; instead pressure-test that they hold.
- **Relay 1.13.0/1.13.1**: closed unauthenticated `/v1/mode`, set-mode, doorbell-ring (pairing-gated);
  real-client-IP rate limiting; external-only SSRF guard on play-url; bounded snooze; **bridge now
  stamps an alert "sent" only after a 2xx and retries 429** (was dropping alerts on relay restart);
  `no_badge` flag; test push no longer dead-ends/badges.
- **iOS correctness**: sync-after-success rollback; badge house-mode filter; NSE badge gate (only real
  `review_id` + not `no_badge`).
- **iOS concurrency (device-UNVERIFIED)**: generation-guards on `TwoWayTalkController` **and**
  `RealtimeVideoController` for the stop()/restart clobber (stuck hot mic / leaked streams); WebRTC
  401 no longer counts toward the per-camera MJPEG lockout; probe cancel-guard (LAN↔tunnel);
  reauth generation-guard (no session resurrection after sign-out); doorbell audio-session release on
  teardown; foreground wall-tile startup gated through `StreamGate`; VoIP token re-register on
  foreground.
- **UI**: error text no longer green; dead buttons report; doorbell VoiceOver labels; 44pt chip
  targets; failure haptics; HouseModeSwitcher flat fill + Reduce Motion; recap deep link.
- **Feature**: the fullscreen **all-cameras grid** (`MultiCameraGridView`) now streams **live**
  (the main wall stays snapshot by design — user's call).

---

## 5. ⚠️ What is DEVICE-UNVERIFIED (tread carefully here)

**The simulator cannot decode WebRTC video or exercise CallKit/VoIP.** So everything in the live-video
and two-way-talk path is verified by compiler + code review only, NOT at runtime:
- `RealtimeVideoController`, `TwoWayTalkController`, `LiveHLSPlayerView` (`HLSLivePlayerView`),
  `MultiCameraGridView` live tiles, `DoorbellCallManager` / CallKit.
- The generation-guard concurrency fixes (build 203) refactored actively-used live code. If you touch
  any of it, keep changes **isolated and revertable**, and say plainly in the commit that it's
  unverified. Do not fold live-video changes into an otherwise-safe build.
- When you propose a fix in this area, prefer the version that can't make things worse if the
  hardware behaves differently than you assume.

If you can get real Frigate credentials into the sim (or a device build), you can actually run-verify
this tier — that is the single highest-value unlock. Otherwise, be conservative.

---

## 6. AUDIT CHECKLIST — the mission (roughly most-impactful first)

Work these as focused passes. For each finding: reproduce/verify by reading the code, propose the
minimal fix, build zero-warning, commit isolated with a clear message. Prefer several small correct
commits over one big sweep.

### A. Backend / relay hardening (`native-ios/apexsight-ha-addon/apexsight-push/`)
- FastAPI `app/main.py`: audit every endpoint for authz (pairing gate), input validation, and error
  handling. Confirm no endpoint can mutate house mode / disarm / ring phones without the gate.
- `app/apns.py`: token handling, `.p8` provider-JWT refresh, dead-token pruning (410/BadDeviceToken),
  environment (sandbox vs prod) correctness. Look for delivery paths that can silently drop.
- `bridge.py`: MQTT `frigate/reviews` → `/v1/notify`. Verify the dedup/`_notified` map can't drop a
  later stage of an alert; confirm reconnect/retry is robust; check the switch-sync watcher.
- `gate.py`: the per-device notification filter. **Invariant: FAIL-OPEN** (deliver unless a confident,
  affirmative mute). Verify no path fails closed and silently suppresses a real alert.
- Rate limiting, SSRF guards, and the snooze/disarm gate: confirm they're sound and can't be bypassed
  or abused, and don't block the in-house bridge.
- SQLite (`db.py`): migrations, concurrent access, no injection, environment never clobbered on
  name-only updates.

### B. iOS correctness & concurrency
- Audit all `Task {}` / async flows for cancellation correctness and actor isolation (`AppState` is
  `@MainActor`). Look for the same class of bug the generation-guards fixed: a stale task mutating
  shared state after a newer one started, or tearing down a resource a newer owner holds.
- `FrigateClient` / `FrigateEventStream`: reconnect/backoff, 401 reauth coalescing, WebSocket
  lifecycle, no leaked observers/timers (CLAUDE.md forbids `Timer.publish` without cancel and
  `DispatchWorkItem`).
- Memory: switching tabs / scrolling the wall for minutes must not grow the heap; players stop on
  disappear unless `persistent`. Image cache (memory+disk) bounds.
- App lifecycle: background/foreground transitions don't leak streams, double-start, or drop the
  house-mode/widget refresh. Deep-link cold-launch races.
- Widgets + NSE: the push→NSE→`reloadAllTimelines` path, timeline budgets, the silent house-mode
  push. (Audited once this session and found healthy — verify it still is after your changes.)

### C. Glass UI polish (the "Apple made it" bar)
- **GlassTheme consistency**: every chrome surface should route through the shared `.liquidGlass(...)`
  modifier / `GlassCard` / `PillButtonStyle`. Flag any ad-hoc materials, **gradients on chrome, or
  colored shadows** (both are against the design system — one was just fixed in HouseModeSwitcher;
  find others). No white cards on the near-black ground.
- **Liquid Glass (iOS 26/27)**: verify glass reads as a subtle lit pane, not a white box, over the
  dark background. Screenshot-verify on the iPhone 17 Pro sim. Use `GlassEffectContainer` where
  adjacent glass should morph.
- **Spacing rhythm** (`GlassTheme.Space` 4pt scale), **radius** tokens, **type hierarchy**,
  **color** tokens (one accent, used sparingly). Hunt inconsistencies.
- **Every state**: loading (skeletons/shimmer), empty, error, offline, no-permission — each screen
  should have a considered version, not a blank or a spinner. Error text must never be success-green
  (just fixed several; check the rest).
- **Motion**: every animation gated on `@Environment(\.accessibilityReduceMotion)`; no continuous
  `repeatForever` that ignores it.
- **Copy**: user-facing strings say what happens, name things by what the user recognizes, errors
  explain the fix. No developer jargon in the UI.

### D. Accessibility
- VoiceOver labels on every icon-only control (several doorbell buttons just fixed — sweep the rest:
  toolbar buttons, PTZ, capability chips, tab badges).
- 44×44pt minimum tap targets (an `hitTarget(_:)` helper exists in `iOS27Modifiers.swift`; the chips
  were just fixed — find other sub-44 controls).
- Dynamic Type: does the layout survive the largest accessibility text sizes without clipping?
- Contrast on glass surfaces; focus order; reduce-transparency behavior.

### E. Security (client side)
- Keychain usage (`SharedTokenStore`, `KeychainStore`): token stored in the shared access group, not
  plaintext plist. Verify nothing sensitive lands in `UserDefaults`/app-group plist or logs.
- Biometric lock (`BiometricLock`) gating disarm; the privacy cover on backgrounding (no live frames
  in the multitasking snapshot).
- ATS is intentionally `NSAllowsArbitraryLoads` (user-supplied Frigate host over LAN/DDNS) — don't
  "tighten" it; it was evaluated and reverted. Do confirm no accidental cleartext to a *cloud* host.

### F. Performance
- The camera wall (snapshot, `LiveSnapshotView`, ~3s refresh) and the live grid (`MultiCameraGridView`
  now live) — verify decode/battery is bounded (LazyVStack stops off-screen decode). Watch the 4K HEVC
  driveway camera (NVENC re-encode).
- Image downsampling, list diffing/stability (Activity feed, Review), no main-thread decode.
- Startup time and the persisted-cameras fast path.

### G. Test coverage
- There are `ApexSightTests` / `ApexSightUITests` targets. Add tests where behavior is subtle and
  regressible: the notification gate (fail-open table), badge counting, deep-link routing, the
  dual-URL resolution, house-mode filtering. The relay has Python tests — extend the gate/delivery
  coverage.

---

## 7. Traps that already cost time (don't rediscover)

- **Wall/away stream keep-warm was built (196–199) and DELETED (200) — it made taps SLOWER** (holding
  extra live decodes contends with the tapped camera). Don't rebuild background keep-warm.
- **Frigate 0.18 removed the HLS live route** — WebRTC-only. A raw RTSP-passthrough go2rtc stream
  reports `.playing` but never paints; needs an ffmpeg re-encode source. See CLAUDE.md "go2rtc source
  gotcha."
- **`/api/config/raw` returns a JSON-encoded string** — `json.loads` before editing.
- **The reliable live-latency probe** is the go2rtc MSE websocket time-to-first-binary, NOT
  `/api/ffprobe` (which false-fails "Invalid data" on chained on-demand streams and caches it).
- **`@available(iOS 27,*)` does NOT gate compilation** against an older SDK — a genuinely-27-only
  symbol needs `#if compiler(>=6.4)`. (Only relevant if you drop to the release SDK.)
- Don't regenerate the xcodeproj expecting it to be tracked — it's gitignored; `project.yml` is the
  source of truth.

---

## 8. How to work (the bar)

- **Small, isolated, bisectable commits.** One logical fix per commit, clear message explaining the
  failure it prevents. Group by subsystem if several fixes share a file.
- **Build zero-warning** before every commit; **archive/ship** only when asked.
- **Verify before you claim done.** If tests fail, say so. If something is device-unverified, say
  that plainly — don't imply runtime verification you didn't do.
- **Get a second opinion on risky/subtle changes** (concurrency, security, live-video) before
  committing to an approach — the cost of a wrong refactor in the live path is high.
- Do **multiple full audit passes** (CLAUDE.md asks for a minimum of 3, continuing until a pass finds
  nothing). Each pass, look for a different class of issue.

---

## 9. Current state (as of this handoff)

_Last updated 2026-08-15 (build 226 / relay 1.23.0). Update this section when you ship._

- **App build 226** on TestFlight (release SDK — see §2), branch `feature/ios27-platform`, pushed,
  tree clean, zero warnings. 176 unit tests in 20 suites + 3 UI tests, all green on this tree.
  **227 carries the server-load fix; build 225 is the version that wedged the Frigate server — see
  §10.** Uploaded 2026-08-15 (`scratchpad/ship226.log`, archive + app + NSE all stamped 226).
  Until both phones actually install it, the household is still running the version that leaks.
- **Relay 1.23.0** on `apexsight-ha-addon` main, pushed AND deployed to HA. 267 checks across
  9 suites. It gained `/v1/diag`, the app's black box — **read it before guessing at any bug**:
  `curl -s "http://192.168.1.203:3421/v1/diag?pairing_code=<code>&limit=200&level=error"`.
  Build 225 added a launch breadcrumb so an empty log unambiguously means "nothing reported"
  rather than "this build never reported". **Nobody has read it since 225 shipped** — that is the
  cheapest first move available to you.
  **⚠️ Its tests are standalone scripts, not pytest** — `pytest tests/` fails on their `raise
  SystemExit`. Run each with `PYTHONPATH=<addon dir> APEX_DATA_DIR=… APEX_SECRET_KEY=… python3 tests/test_x.py`.

**Open verification the user owns** (all compiler-and-tests-only; the simulator cannot exercise them):
- Two-way talk end-to-end on a device — never confirmed working, and several fixes now sit on that
  unverified baseline. Build 221 at least makes its failures *visible*, which is the missing
  diagnostic: hold the button and read the red capsule.
- The privacy cover / Face ID lock drawn over an OPEN SHEET (build 221's `SecurityCoverWindow`). Its
  create/dismiss lifecycle was sim-verified; the over-a-sheet case and Face ID itself were not.
- The live all-cameras grid.

**Known-open, ranked** (nothing here is a regression; they're unstarted work):
1. **The wall uses the full `main` stream for the three cameras with no `_sub`** (doorbell,
   movie_room, Ryleighs_Rm — confirmed against the live go2rtc stream list). **Deliberately NOT
   fixed, and think before you do**: giving them subs means either finding each camera's native
   substream URL (the doorbell is an Aqara behind Scrypted, so there may not be one) or adding an
   ffmpeg downscale, which puts *more* transcode on a 1080 Ti already running TensorRT + NVENC +
   Scrypted. That could easily cost more than the phone-side decode it saves. Measure first.
2. **Device battery / thermals on the wall have never been profiled.** The simulator says ~240 MB
   RSS drifting *down* 81 MB over 95s at 2–13% CPU, and heap growth was separately measured clean —
   but the sim decodes on the Mac's hardware, so none of that predicts an iPhone with the 4K HEVC
   driveway camera. This needs Instruments on a real device.
3. Doorbell first-open cold start (~8s, on-demand NVENC re-encode). **⚠️ Do NOT "fix" this by
   rebuilding stream keep-warm** — that was built in 196–199 and deleted in 200 because it made taps
   SLOWER (see §7). A ring already pre-warms the stream, which is the case that matters.

_Items 1–2 of the previous list (review stills in notifications/CarPlay, and the MJPEG fallback)
were closed in build 222. The old CLAUDE.md watch-item "MJPEG fallback keys off `.playing`, not real
frames" was already stale before that — `evaluatePlaying()` has required a non-zero
`presentationSize` for a while; 222 tightened it further to "live pixels actually on screen"._

- The single biggest unlock for deeper auditing is unchanged: **run-verifiable live video from a
  device**, so the WebRTC/talk tier stops being compiler-only.

---

## 10. ⛔⛔ THE APP WEDGED THE FRIGATE SERVER (2026-08-14) — read this before touching networking

**The whole NVR was unavailable for ~7 hours.** Frigate's API answered nothing; 1328 consecutive
healthchecks timed out. Cameras kept recording, but nothing could be viewed and HA automations that
poll Frigate stalled. The cause was **this app's client behaviour** against a latent Frigate flaw.

### Mechanism
1. The app requests a preview / snapshot / clip. Frigate answers by spawning
   `ffmpeg -f concat -i /tmp/cache/playlist_<Camera>_<ts>.txt -c copy -f mp4 pipe:`.
2. The response is slow — recordings live on a spinning array, and the client is remote over a
   Cloudflare tunnel.
3. **The app walks away.** nginx logs `499` (client closed request) at `request_time="125.0"`.
4. Nobody drains ffmpeg's pipe. It blocks on a full buffer, never exits, and holds an API worker.
5. One leaked roughly every 22 minutes for 15+ hours until the worker pool was exhausted.

Server-side evidence: **73 ffmpeg processes for 9 cameras** (normal ≈33), 40 of them orphaned
`playlist_*` exports. Killing exactly those 40 took the API from "timeout after 20s" to "HTTP 200
in 0.007s" instantly. Recorded user agents: `ApexSightNative/225`, `ApexSightNotificationService/225`.

### ⚠️ The client defect — and the thing that is easy to get wrong
**`URLRequest.timeoutInterval` is an IDLE timeout, not a total one.** It measures the gap between
packets, so a server trickling bytes out of an ffmpeg pipe resets it indefinitely. The app set it in
~20 places and set `timeoutIntervalForResource` — the real wall-clock cap — in three. **Every
extension used `URLSession.shared`, whose resource timeout is seven days.** That is how a request
with an apparent 8-second limit reached 125 seconds.

Note this cuts against an older, correct observation in the repo's memory: for a big NSE download,
an idle timeout is a *feature* (780 KB can't spuriously fail where 188 KB succeeded). Against an
ffmpeg pipe it is the opposite. Both facts are true; you need the total cap as well.

### What was fixed (this session, committed, NOT yet shipped)
- **`Sources/ApexSightShared/BoundedSession.swift`** — Frigate sessions with a real
  `timeoutIntervalForResource` plus `httpMaximumConnectionsPerHost`. The NSE (12s total) and the
  widgets (15s) now use it; so do `probeLiveHLS` and the Visual Intelligence thumbnail fetch.
- **`FrigateClient.downloadSession` resource timeout 3600s → 180s**, `waitsForConnectivity` off. An
  hour-long cap is what turned a stalled export into a server-side leak.
- **`FrigateClient.apiSession` capped at 3 connections per host** so a nine-camera wall cannot
  arrive as nine simultaneous requests.
- **`Sources/ApexSight/Helpers/SnapshotPollPolicy.swift`** — the wall polled on a fixed 3s tick with
  *no failure path at all*. Now: ~3s when the server answers fast, stretched proportionally when it
  is slow, exponential backoff on failure, and a once-a-minute heartbeat after 5 consecutive
  failures. **Deliberately not a hard stop** — a security wall that silently stops updating until
  the user interacts is a worse failure than one quietly checking once a minute.
- **The wall now stops entirely when the app is not foregrounded** (`.task(id:)` keyed on
  `scenePhase`). It used to keep polling until iOS got round to suspending it.
- **`Sources/ApexSightShared/NotificationMediaCache.swift`** — an alert arrives as two pushes
  (instant, then the AI follow-up that replaces it), and each ran the NSE and re-downloaded the
  same picture. Stills are now reused for 5 minutes. **GIFs are excluded on purpose**: the
  follow-up push exists to carry the *finished* animation, so caching it would pin every alert to
  its first second of footage.
- `Tests/ApexSightTests/ServerLoadPolicyTests.swift` pins all of it, including "no Frigate session
  may have a resource timeout over 300s" — which fails loudly if anyone reaches for
  `URLSession.shared` again.

### ⚠️ NOT verified — this is the next engineer's job
Everything above is compile-and-test verified only. **Nobody has watched the server while using the
patched app**, because the fix has not been uploaded to TestFlight.

**⚠️ THE FOREGROUND GATE BIT ONCE ALREADY — don't re-introduce it.** The wall's `.task(id:)` was
first keyed on `scenePhase == .active`, which is wrong in the direction this whole section exists to
prevent. `.inactive` is not backgrounded: it fires for a notification banner, Control Centre, the
app switcher, an incoming call. Keyed that way, each of those tore the task down and rebuilt it, and
**a rebuilt task fetches immediately — so one banner became nine simultaneous requests**, during
exactly the alert storms when the server is already loaded. It is now keyed on `!= .background`,
matching what `ApexSightApp.swift` has always done for the foreground poller (`.background` stops
it, `.inactive` deliberately does not). If you touch this, match that convention.

Two guards back it up, because the teardown itself depends on SwiftUI re-evaluating the view on a
phase change — an assumption no test here can assert. Each fetch is gated on
`UIApplication.shared.applicationState` directly and **skips rather than returns**, so the loop
resumes whether or not the task was rebuilt; and `SnapshotPollPolicy.initialDelay` makes a restarted
tile serve out the remainder of the interval the previous fetch began, so a rebuild from *any* cause
cannot become an instant nine-way fetch. A tile that has never fetched still paints immediately — a
wall loading is not a burst.

(Note also that `LiveSnapshotView.interval` is now only a *floor* — `SnapshotPollPolicy` owns the
cadence — so setting it does not do what its name suggests.)

Verify the server side like this:

```bash
# ffmpeg count while using the app hard — should hover ~33 for 9 cameras and come back down
watch -n5 'docker exec frigate_LPR sh -c "pgrep -c ffmpeg"'

# 499s are the direct signature of the app abandoning a request. Target: ZERO.
docker logs --tail 500 frigate_LPR 2>&1 | grep ' 499 ' | grep ApexSight
```
Any 499 with `request_time="125"` means a request was left to rot.

**⭐ You do not need SSH or docker for the first check** — Frigate's own `/api/stats` reports every
process it owns, cmdline included, so this runs from any machine on the LAN and is the fastest way
to see whether exports are accumulating:
```bash
curl -s http://192.168.1.204:5000/api/stats | python3 -c "
import json,sys
cpu = json.load(sys.stdin).get('cpu_usages', {})
ff = [v.get('cmdline','') for v in cpu.values() if 'ffmpeg' in str(v.get('cmdline',''))]
print('ffmpeg:', len(ff), '| orphan-shaped playlist_ exports:', sum('playlist_' in c for c in ff))"
```
**Baseline measured 2026-08-15 on a healthy server: `ffmpeg: 33 | orphan-shaped: 0` for 9 cameras.**
A non-zero second number that does not fall back to zero is the leak. (The API answered in 0.15s at
the same moment, so the server was genuinely healthy — the number is a real baseline, not a
reading taken while it was already degraded.)

### Server-side context (already done, no app action needed)
- Server upgraded to Frigate `0.18.0-beta3-tensorrt`, which adds a generic subprocess watchdog that
  may reap stalled children.
- The 40 orphaned ffmpegs were cleared; the API recovered without a restart.
- **Assume a slow, lossy link, not LAN.** Frigate is behind a Cloudflare tunnel, so the app's
  requests arrive from a public IP carrying real latency.

### Still open in this area
- `RelayClient` / `SharedRelayGate` / `SharedHouseModeFetch` / `DiagnosticLog` still use
  `URLSession.shared`. They talk to the **relay**, not Frigate, and nothing there spawns ffmpeg, so
  they were left alone — but `RelayClient.swift:395` deliberately holds a 150s long-poll, so read
  the intent before "fixing" any of them.
- AVPlayer's own HTTP (live HLS, VOD playback) is outside `URLSession` and cannot be given a
  resource cap. `LiveHLSPlayerView` already backs off exponentially (capped 16s, max 8 attempts);
  if 499s persist after this build, that is the next place to look.

Good luck. Make it feel like Apple made it.
