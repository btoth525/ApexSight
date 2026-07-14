# ApexSight — Audit & Hardening Handoff

**You are picking up a mature, shipping iOS app (build 206) + its Home-Assistant push relay.**
Your job: audit, harden, and polish it toward "Apple-made-it" quality — UI, backend, correctness,
security, performance, accessibility. This doc is the mission brief + current state + the traps that
will waste your time if you don't know them. Read `CLAUDE.md` (repo root) first for the full
architecture and design system; this file assumes it.

---

## 0. TL;DR — do this first

1. Read `CLAUDE.md` (architecture, GlassTheme design system, the 5 tabs, stream architecture).
2. **Build with the iOS 27 BETA SDK** — see §2. Building with the wrong Xcode wastes an hour.
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
  distributed via TestFlight only. This is why we ship on the beta SDK (§2).

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

**Ship with the iOS 27 BETA SDK.** Both users' phones are on iOS 27 and the app uses 27-only APIs
(nav-bar `toolbarMinimizeBehavior`, Apple Intelligence vision, NowPlaying). It is TestFlight-only, so
Apple's `ITMS-90534: Unsupported SDK` email on every upload is **expected and harmless** (it only
blocks public App Store submission, which we don't do). **Do NOT "fix" that warning by switching to
the release Xcode — it silently drops the iOS 27 features.**

```bash
# The correct toolchain:
export DEVELOPER_DIR=/Users/brandon/Downloads/Xcode-beta.app/Contents/Developer   # Xcode 27.0 / Swift 6.4

# Build for the simulator (zero-warning target):
cd /Users/brandon/apexsight/native-ios
xcodegen generate   # ALWAYS after any project.yml change or new file, else stale build number
xcodebuild -project ApexSightNative.xcodeproj -scheme ApexSightNative \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" -configuration Debug build \
  2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"
```
- **Sim device is `iPhone 17 Pro`** (iPhone 16 Pro no longer exists; CLAUDE.md may still say 16).
- The code is *also* release-SDK-portable as a fallback: the one 27-only symbol is guarded
  `#if compiler(>=6.4)` and `MainTabView.body` is split so the 6.3.2 type-checker doesn't time out.
  Both toolchains build clean — but **ship the beta 27**.
- **Ship pipeline**: bump `CURRENT_PROJECT_VERSION` in `project.yml` → `xcodegen generate` →
  `xcodebuild archive` (generic/platform=iOS) → `-exportArchive` with `-allowProvisioningUpdates`
  (auths off the signed-in Xcode session, no API key). See `native-ios/scratchpad/ship206.sh` for the
  exact recipe. Never run two archives at once. Bump the build number every upload.

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

- **App build 206** on TestFlight (iOS 27 SDK), branch `feature/ios27-platform`, pushed. Zero
  warnings. Contains all of §4.
- **Relay 1.13.1** on `apexsight-ha-addon` main, pushed.
- **Open verification the user owns**: device-test two-way talk (build 201's talk was never confirmed
  working; the R1 refactor sits on that unverified baseline) and the live all-cameras grid.
- The single biggest unlock for deeper auditing: **run-verifiable Frigate access from the sim/device**
  so the live-video/talk tier stops being compiler-only.

Good luck. Make it feel like Apple made it.
