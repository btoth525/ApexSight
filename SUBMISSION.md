# ApexSight — App Store Submission Kit

Everything needed to submit ApexSight to the App Store. Copy/paste the listing
fields into App Store Connect, and read the **App Review Notes** section — it's the
one thing most likely to get a server-client app rejected.

---

## 0. ⚠️ The #1 blocker: App Review needs a way to test

ApexSight is a **client for a Frigate NVR server**. Without a reachable Frigate
server + login, a reviewer sees only the sign-in screen and will reject under
Guideline 2.1 ("we were unable to review your app"). You MUST give them a way in.

Pick one before submitting:

- **Best — a demo Frigate server.** Stand up (or temporarily expose) a Frigate
  instance reachable from the public internet, with a read-only user. Put the URL +
  username + password in **App Review Notes** (template below). Leave it up until
  the review passes.
- **Alternatively — a guest/demo mode in the app** (mock cameras + sample events,
  no server). This is a code feature I can build if you'd rather not expose a
  server — just say the word.

Until one of these is in place, do not submit.

---

## 1. Pre-flight checklist (code/config — already done ✅)

- ✅ Privacy manifests (`PrivacyInfo.xcprivacy`) in all bundles
- ✅ `ITSAppUsesNonExemptEncryption = false` (export compliance auto-cleared)
- ✅ Only used permissions declared (Local Network, Notifications, Photos add,
  Face ID); unused Camera permission removed
- ✅ Privacy policy written (`PRIVACY.md`) — host it and use the URL below
- ✅ App icon (1024) + launch screen color present
- ✅ No personal data / sample names hardcoded

Still to confirm in Xcode/App Store Connect:

- [ ] Bump `CURRENT_PROJECT_VERSION` (build number) in `native-ios/project.yml`
      for each upload; `MARKETING_VERSION` is `1.0.0`.
- [ ] **CarPlay**: the `com.apple.developer.carplay-driving-task` entitlement must
      be granted to your account or the upload fails. If it's not granted, remove
      CarPlay (ask me — 2-minute change) before archiving.
- [ ] Signing & Capabilities: Team selected, automatic signing resolves.
- [ ] Push: APNs key uploaded to the relay; the relay's bundle id matches
      `com.brandontoth.apexsight.native`.

---

## 2. App Store Connect — listing fields (copy/paste)

**Name:** `ApexSight`

**Subtitle** (≤30): `Live viewer for Frigate NVR`

**Promotional text** (≤170):
`Your Frigate cameras, beautifully native: live view, instant rich alerts,
Live Activities, widgets, Siri, CarPlay, and Apple Watch.`

**Description:**
```
ApexSight is a fast, native iOS client for your own Frigate NVR — built to be the
best way to watch your cameras and stay on top of what matters.

LIVE & SMOOTH
• Low-latency live view over HLS, single camera or a multi-camera wall
• Scrub recordings and review detection clips
• Snapshot and full-frame views

ALERTS THAT RESPECT YOU
• Instant rich notifications with snapshots, even when the app is closed
• Live Activities: a live incident banner on your Lock Screen and Dynamic Island
• Per-camera, per-zone, per-object rules, quiet hours, and cooldowns to kill
  alert fatigue
• Arm / Disarm / Snooze from the app, a widget, Siri, or Control Center

EVERYWHERE YOU ARE
• Home Screen, Lock Screen, and StandBy widgets
• Apple Watch app with recent alerts
• CarPlay glanceable alerts and camera stills
• Siri Shortcuts and App Intents

PRIVATE BY DESIGN
• Local-first: connects to YOUR Frigate server. No accounts, no analytics, no
  telemetry. Credentials stay in your iOS Keychain.
• Optional Face ID app lock.

ApexSight requires your own Frigate NVR (frigate.video). It is not affiliated with
the Frigate project.
```

**Keywords** (≤100, no spaces after commas):
`frigate,nvr,security,camera,cctv,surveillance,home,rtsp,go2rtc,ip camera,alerts,live view,watch`

**Support URL:** `https://github.com/btoth525/apexsight` (or your support page)
**Marketing URL:** (optional) same as above
**Privacy Policy URL:** host `PRIVACY.md` (GitHub Pages or the raw file URL)

**Primary category:** Utilities  ·  **Secondary:** Lifestyle
**Age rating:** 4+
**Price:** Free

---

## 3. App Review Notes (paste into App Store Connect)

```
ApexSight is a client for a self-hosted Frigate NVR (frigate.video). To review all
functionality, sign in with this demo server:

  Server URL: https://<YOUR-DEMO-FRIGATE-URL>
  Username:   <demo-user>
  Password:   <demo-pass>

Notes for the reviewer:
• Live View, Review, Activity, and Search all populate from the demo server above.
• Push notifications are delivered via our relay; the app auto-pairs on first
  launch, so no setup is required to receive alerts.
• Face ID app lock is OFF by default (Settings → Require Face ID).
• Optional features: Apple Watch app, Home/Lock Screen widgets, CarPlay (glanceable
  alerts only; no video while driving), Siri Shortcuts.

No account creation is required by ApexSight itself; the only "login" is to the
user's own Frigate server.
```

(If you ship a demo/guest mode instead, say so here and tell the reviewer to tap
"Try the demo" on the sign-in screen.)

---

## 4. Screenshots — shot list (6.7" + 6.1" required; 12.9" iPad if iPad-enabled)

1. **Live multi-camera wall** — the hero shot
2. **Single live view** with the controls
3. **Review tab** with a rich detection + snapshot
4. **A Live Activity / Dynamic Island incident** (Lock Screen)
5. **Notification settings** (per-camera, quiet hours) — show the depth
6. **Widgets on the Home/Lock Screen** (+ StandBy if you can capture it)

Tip: capture on a device with real cameras for punch, then add short captions.

---

## 5. After it's live

- Tag the release in git and bump the build number for the next upload.
- Watch App Store Connect → App Analytics + Crashes for the first week.
```
