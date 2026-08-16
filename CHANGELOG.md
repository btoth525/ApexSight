# Changelog

All notable changes to ApexSight (the native iOS client for Frigate NVR).

The project follows a single rolling `CFBundleVersion` (build number) tracked in
`native-ios/project.yml`. Marketing version is `1.0.0`.

## Build 228 (2026-08-15) — two things the app was doing to itself

### Removed — an iOS Focus could switch off your home security

Turning on a Focus — Sleep, Driving, Do Not Disturb — silenced the cameras for as long as it was
on, and the only sign was a small banner you had to open the app to find. ApexSight no longer
appears in Settings → Focus → Focus Filters at all, and a mute left behind by an earlier version
clears itself the first time this build syncs.

iOS still decides whether to *show* a notification while a Focus is on. Alerts above routine are
sent as time-sensitive and break through; quiet, routine ones stay quiet. That part is Apple's, not
the app's.

### Removed — the live bounding boxes that pointed at nothing

On the wide cameras the orange "Car" and "Person" chips drew in the black bar underneath the
picture instead of on the thing they were labelling. They will come back when they can be placed
correctly.

## Builds 225–227 (2026-08-10 → 08-15) — the app stops overwhelming the server it depends on

### Added (225) — the diagnostics log can now prove it is working

Every launch records the build it is running, so an empty log unambiguously means nothing went
wrong rather than "this version never reported anything". A live tile dropping to the low-resolution
fallback, and two-way talk failing, are both recorded too — things you'd notice and the app didn't
consider errors, so neither left any trace.

### Fixed (226) — the app was taking the cameras offline

The Frigate server went fully unresponsive for about seven hours. Nothing could be viewed, and the
automations that poll it stalled, though the cameras kept recording throughout. The cause was this
app.

Frigate builds previews, snapshots and clip exports by starting an ffmpeg and streaming its output.
When the app asked for one of those over a slow connection and then gave up waiting, nobody was left
reading that output — so the ffmpeg never finished, and it held on to one of the server's limited
workers permanently. Forty accumulated over fifteen hours, roughly one every twenty minutes, until
there were none left and the server could not answer anything at all.

Underneath it was a single misunderstanding about how a request expires. The limits the app set
measured the pause *between* pieces of a response, not the length of the whole thing, so a server
sending a trickle of data could keep a request alive indefinitely — and the notification and widget
code had no overall limit at all, defaulting to seven days. Every request to Frigate now has a real
ceiling on its total life, and the app opens fewer of them at once.

- **The camera wall now follows the server's pace.** It asked for a fresh frame from every camera
  every three seconds no matter what — including when the server was failing to answer and when
  the app wasn't even on screen. It stays at three seconds when the server is quick, eases off as
  the server slows, backs off after failures, and settles to a check-in once a minute if a camera
  stays unreachable. It never stops entirely: a wall that goes quiet until you think to poke it is
  worse than one that keeps looking.
- **The wall stops when the app isn't in front of you**, rather than fetching pictures nobody can
  see until iOS gets round to suspending it.
- **An alert no longer downloads its picture twice.** Every alert arrives as two notifications — the
  immediate one, then the one that replaces it with the finished summary — and each was fetching the
  same still from scratch. Animated previews are still fetched fresh both times, on purpose: the
  second notification exists precisely to carry the completed clip.
- **The camera wall now records when it gives up on a camera and when it recovers**, so a
  "why did that tile look stale" question has an answer afterwards instead of a guess.

### Fixed (227) — the previous build's own fix had a sting in it

The change that stops the wall fetching while the app is away treated a notification banner, Control
Centre and the app switcher as "away" — and coming back from any of them made every tile ask for a
frame at once. Alert banners arrive in groups, so this landed hardest exactly when the server was
busiest. Only genuinely leaving the app stops the wall now, and a tile that resumes waits out the
rest of its interval rather than firing straight away.

## Builds 215–224 (2026-07-28 → 08-10) — the AI review story, then a deep correctness sweep

### Fixed — things the app was telling you that weren't true
- **Review alerts showed a picture from the wrong day.** A review's still resolved through one of
  its detections, and Frigate keeps re-choosing that object's "best frame" for as long as the track
  lives — so a parked car re-linked into a fresh review illustrated it with a frame from hours
  earlier. Measured over three days: 27 of 157 alerts, 10 of them off by more than five minutes; the
  worst showed a different vehicle from 16.5 hours before, with Frigate's own burnt-in timestamp
  proving it. The still is now pinned into the review's own window when — and only when — the
  object's frame falls outside it.
- **The Lock Screen widget could say the house was armed when the arm had failed.** The Control
  Center / widget arm control discarded the relay's response and repainted itself regardless.
- **Siri's alerts toggle spoke like the alarm.** "ApexSight is now Away" borrowed the house-mode
  vocabulary for what is only the app's notification gate; it now says "Camera alerts are now off".
- **A failed detections poll rendered "No Detections"** — a security app affirmatively reporting
  nothing was there when it had simply failed to ask.
- **The widget hero could show an unrelated camera's live frame under an alert caption.**
- **Live detection boxes never drew at all**, on any camera: Frigate's WebSocket payload carries no
  frame dimensions, so every box was discarded. They now fall back to the camera's detect resolution.

### Fixed — alerts and state that could go missing
- Signing out or switching servers mid-refresh could publish (and persist) the previous server's
  cameras, events and reviews over the cleared state; "Mark All Reviewed" could empty the *new*
  server's queue and zero the badge.
- A notification tapped on a cold launch could be dropped entirely instead of routed.
- A background re-auth wiped the saved home-network URL, so the app silently ran every stream over
  the tunnel while sitting at home.
- One surprising field in one review can no longer fail the decode of the whole Review tab.
- Camera Recording/Detect toggles confirmed changes the live socket never actually sent.
- A single timed-out probe at launch could pin the whole session to a dead video pipeline.

### Fixed — security
- The notification extension attached the Frigate session token to image URLs taken from the push
  payload; it now only ever sends credentials to the origin the app signed in to.
- A Keychain recovery write downgraded the stored token to a backup-eligible protection class.

### Fixed — privacy and security (build 221)
- **The privacy cover and Face ID lock now cover sheets.** Both were overlays on the root view, and
  iOS presents sheets above that — so with a review, the camera controls or the fullscreen viewer
  open, the app-switcher snapshot still showed live camera frames, and the Face ID lock rendered
  *behind* the sheet with its content visible and interactive. A lock you can reach around is not a
  lock. They now render in their own window above everything the app presents.
- **Two-way talk says why it failed.** Holding "Hold to Talk" with the microphone denied did
  nothing at all and explained nothing; the reason is now shown, and the microphone message points
  at the Settings switch that fixes it.
- **A threat level written as `2.0` no longer reads as Routine** — an AI-flagged review kept losing
  its badge to a decoding technicality.

### Fixed — the last sweep (build 222)
- **Notifications the app raises itself, and CarPlay, now pin the review still too.** The relay
  clamps the image on the push path, so those two were the last places an alert could be
  illustrated with a frame from a different day. It matters most on CarPlay, where the picture is
  nearly all you get and you are glancing at it while driving.
- **A live tile that never paints now falls back instead of sitting on a frozen snapshot.** The
  fallback judged on the player reporting "playing"; a stream can report that, know its dimensions,
  and still never hand the screen a frame. It now judges on whether live pixels are actually on
  screen — on a security camera, a still that stopped being true ten seconds ago reads as "nothing
  is happening".

### Fixed — the AI cards (build 223)
- **Summaries no longer stop mid-word.** Frigate hard-clamps its short summary to 140 characters
  and cuts blind — measured across 61 rated reviews, **22 (36%) ended mid-sentence**. The app now
  shows whichever field is an actual finished sentence, and only abbreviates (with an ellipsis)
  when there is nothing whole to show.
- **A fabricated "Forced Entry Attempt" can no longer raise the alarm.** One review was rated the
  highest severity, complete with an imagined crowbar, against two **face-recognised residents
  carrying a package** — at the model's own confidence of **0.02**. An escalation is now ignored
  when the model isn't confident, or when it's about someone the cameras recognise. An untrusted
  rating shows as unrated rather than as a green all-clear, because "we don't believe this" and
  "this is normal" are not the same statement. A confident warning about a stranger still comes
  through exactly as before.

### Added — a black box (build 224)
- **The app now keeps a log of its own errors and sends it to your relay**, so a problem you hit
  while testing can be looked at afterwards instead of being lost. Until now the app only logged
  in debug builds, which meant the TestFlight builds you actually use recorded nothing at all.
  There's a switch in Settings → Diagnostics. It never leaves your household, and tokens, passwords
  and your pairing code are stripped out *before* anything is written down — not just before it's
  sent. Needs relay 1.23.0.

### Added
- **Frigate's AI review story in the Review tab** — headline, threat level, and the play-by-play
  behind a disclosure — with the rating driving how loudly a notification interrupts you.
- Traffic-light alert titles (green routine / yellow notable / red concerning).

## Builds 213–214 (2026-07-26/27) — a Focus stops silencing the household

### Fixed
- **One phone's iOS Focus no longer silences everyone's cameras.** The Focus filter wrote the
  *household* gate, so a partner turning on Do Not Disturb muted every phone for eight hours with
  nothing on screen explaining it. Focus mutes are now per-device (`/v1/focus-mute`), and a phone
  muted by its own Focus says so. Requires add-on 1.16.0+.
- **The household gate records who silenced it and when** — the banner now reads "Set by
  Brandons Iphone at 2:16 PM" instead of leaving you to guess.
- **A cold launch no longer re-imposes a stale local snooze** over household state, and clearing
  the snooze on one phone is adopted by the other. The sync marker is split into "attempted"
  (in-memory) and "confirmed" (persisted, written only on a 2xx) so neither over- nor under-posting
  is possible; both directions are pinned by `GateSyncPolicy` tests.
- **Resuming alerts retries** instead of failing silently — dropping that request was fail-closed.
- Picture-in-Picture stops when the biometric lock engages.

### Changed
- App Intent metadata is `static let`, removing 174 strict-concurrency warnings (317 → 132 under
  `SWIFT_STRICT_CONCURRENCY=complete`); `Haptics` states the main-actor isolation it always relied
  on. The normal build remains at **zero warnings**.
- Explore's filter chips stop rebuilding their option sets twice per render.
- Verified, not assumed: no heap growth across sustained tab switching, and App Intents
  registration is byte-identical before and after the metadata change.

## Builds 188–212 (2026-07-12 → 07-18) — Frigate 0.18, doorbell talk, hardening

### Added
- **Live two-way talk** at the doorbell — hold to talk, mic published over WebRTC and piped to the
  Aqara speaker natively over the LAN. Plus a soundboard and TTS replies.
- **Dual-URL auto-switch** (home vs away) with host-only ICE on the LAN, and stream pre-warm during
  a doorbell ring.
- Apple Watch, CarPlay and Apple TV companions; Siri Shortcuts / App Intents; Control Center
  controls; daily recap.

### Fixed
- **Frigate 0.18 removed the nginx HLS proxy route**, breaking live view. Live is now
  WebRTC-primary with an MJPEG fallback, and the app probes so 0.17 behaviour is unchanged.
- Notification copy no longer mis-pairs an object with an unrelated sub-label; the widget hero
  image matches its caption; incidents no longer cluster unrelated cameras.
- The "Snooze Alerts" Home Screen quick action now asks for confirmation — an accidental
  long-press used to silence the whole household for an hour instantly.
- Keychain hardening: the app has its own private access group, and the pairing code moved out of
  a plaintext app-group plist.
- Accessibility: Reduce Transparency and Increase Contrast are honoured app-wide; the lock screen
  scales with Dynamic Type; security-relevant text is off the lowest contrast tier.

### Removed
- Away/wall keep-warm streaming — measured *slower*, not faster, because the extra consumers
  competed with the camera actually being watched.

## Repository cleanup

### Removed
- Legacy Expo / React Native prototype (`app/`, `components/`, `stores/`, `hooks/`,
  `utils/`, and the Expo/Metro/NativeWind tooling). The native SwiftUI app fully
  supersedes it; the repository is now Swift + the Python push companions only.

## Builds 183–187 (2026-07-12) — house-mode notifications, CallKit revival, widgets
### Added
- **House Mode Alerts editor** (Settings → Notifications): per-mode (Home/Night/Away) ×
  per-camera alert matrix, household-wide via the relay's new `/v1/mode-map`; current-mode
  "NOW" chip, reset-to-defaults, live sync badge. (Add-on 1.10.5+)
- **Household snooze/disarm banner** on the camera wall + Notifications settings — a snooze
  set from Siri/a widget/a partner's phone used to silence every push invisibly; now it's
  loud and one tap resumes alerts for everyone.
- **Widgets follow house mode with the app closed** (build 187): the relay silent-pushes
  every phone on a mode change and the Lock Screen widget verifies against the relay on
  every timeline build. (Add-on 1.10.8)
- Per-device notification sections labeled "This iPhone only" to distinguish them from the
  household matrix.
### Fixed
- **Doorbell CallKit rings dying permanently** (build 184): a duplicate-press guard swallowed
  VoIP pushes without reporting a call — iOS blacklists the app from VoIP delivery for that
  (delete + reinstall required once). Every push is now always reported; unanswered rings
  time out after 45s; answer-vs-timeout race fixed; doorbell calls no longer clutter Phone
  Recents (build 185).
- House Mode editor no longer shows everything-ON when the relay predates the matrix —
  seeds the true built-in defaults and locks editing with an update notice.
- Editor saves serialized (debounced latest-wins) so rapid toggling can't land out of order;
  camera roster always includes never-muted cameras.

(Builds 164–182 shipped without changelog entries — see git log for the doorbell call/talkback,
house-mode arm/disarm, per-phone HA entities, and streaming work.)

## Build 163
### Added
- **All notification settings now apply when the app is closed.** Each device syncs its own
  notification preferences to the push relay — per-camera, per-object, and per-zone mutes, quiet
  hours, per-camera snoozes, and custom triggers — so remote pushes are filtered per device exactly
  like foreground alerts. Previously only Disarm, Snooze-all, and whole-camera mutes carried over.
  Syncs the moment a setting changes and on every foreground. (Requires ApexSight Push add-on 1.5.0.)
  Disarm and Snooze-all remain system-wide across your devices.

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
