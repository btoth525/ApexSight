# ApexSight — App Store Submission Kit

Everything needed to submit ApexSight (account-based build) to the App Store.
Read sections 0 and 3 — they're what actually gets a server-client app rejected.

---

## 0. ⚠️ The two things that get this rejected

**a) App Review must be able to sign in and see cameras.** ApexSight needs an
account *and* a reachable Frigate. Give the reviewer a ready-to-use demo **account**
that already has a demo Frigate linked, so they sign in and everything works:

- Create an account (e.g. `review@apexsight.app`) on the website.
- Link a **reachable** demo Frigate to it (publicly reachable URL + read-only user).
- Put that account's email + password in **App Review Notes** (template in §3).
- Leave both up until review passes.

**b) In-app account deletion is required (Guideline 5.1.1(v)).** ✅ Done — it's in
**Settings → Account → Delete Account**. Call this out in the review notes (§3).

---

## 1. Pre-flight checklist

Code/config — already done ✅
- ✅ Privacy manifests (`PrivacyInfo.xcprivacy`) in all bundles
- ✅ `ITSAppUsesNonExemptEncryption = false` (export compliance auto-cleared)
- ✅ Only used permissions declared (Local Network, Notifications, Photos add, Face ID)
- ✅ In-app account deletion (Settings → Account → Delete Account)
- ✅ Privacy policy reflects accounts; served at `/privacy` and in `PRIVACY.md`
- ✅ App icon (1024) + launch screen color present
- ✅ No personal data / sample names hardcoded

Confirm in Xcode / App Store Connect / Apple Developer:
- [ ] **Sign in with Apple** capability enabled on the App ID (the entitlement ships
      in the app; the App ID must allow it or signing fails).
- [ ] Bump `CURRENT_PROJECT_VERSION` (build number) per upload; `MARKETING_VERSION` 1.0.0.
- [ ] **CarPlay**: `com.apple.developer.carplay-driving-task` must be granted to your
      account or the upload fails — if not granted, ask me to strip CarPlay first.
- [ ] Signing & Capabilities: Team selected, automatic signing resolves.
- [ ] APNs key uploaded to the relay; relay bundle id = `com.brandontoth.apexsight.native`.
- [ ] Relay reachable at your production domain (see DEPLOYMENT below) with HTTPS.

---

## 2. App Store Connect — listing fields (copy/paste)

**Name:** `ApexSight`
**Subtitle** (≤30): `Live viewer for Frigate NVR`

**Promotional text** (≤170):
`Your Frigate cameras, beautifully native: live view, instant rich alerts,
Live Activities, widgets, Siri, CarPlay, and Apple Watch.`

**Description:**
```
ApexSight is a fast, native iOS client for your own Frigate NVR — the best way to
watch your cameras and stay on top of what matters.

LIVE & SMOOTH
• Low-latency live view over HLS, single camera or a multi-camera wall
• Scrub recordings and review detection clips

ALERTS THAT RESPECT YOU
• Instant rich notifications with snapshots, even when the app is closed
• Live Activities: a live incident banner on your Lock Screen and Dynamic Island
• Per-camera, per-zone rules, quiet hours, and cooldowns to kill alert fatigue
• Arm / Disarm / Snooze from the app, a widget, Siri, or Control Center

EVERYWHERE YOU ARE
• Home Screen, Lock Screen, and StandBy widgets
• Apple Watch app, CarPlay glanceable alerts, Siri Shortcuts

PRIVATE BY DESIGN
• Connects to YOUR Frigate server. No analytics, no tracking, no ads.
• Your Frigate password is encrypted; optional Face ID app lock.

Create a free account, link your own Frigate NVR (frigate.video), and sign in.
ApexSight is not affiliated with the Frigate project.
```

**Keywords** (≤100): `frigate,nvr,security,camera,cctv,surveillance,home,rtsp,go2rtc,ip camera,alerts,live view,watch`

**Support URL:** `https://apexsight.app`
**Marketing URL:** `https://apexsight.app`
**Privacy Policy URL:** `https://apexsight.app/privacy`

**Primary category:** Utilities · **Secondary:** Lifestyle
**Age rating:** 4+ · **Price:** Free

---

## 3. App Review Notes (paste into App Store Connect)

```
ApexSight is a companion for a self-hosted Frigate NVR (frigate.video). Sign in with
this demo account, which already has a demo Frigate linked, to review everything:

  Email:    review@apexsight.app
  Password: <demo-account-password>

Notes for the reviewer:
• Sign in with the account above (or "Sign in with Apple", or create a new account).
  After sign-in the app connects to the linked Frigate automatically.
• Account deletion: Settings → Account → Delete Account (removes all account data).
• Push notifications are delivered via our relay, routed privately per account.
• Face ID app lock is OFF by default (Settings → Require Face ID).
• Optional: Apple Watch app, Home/Lock Screen widgets, CarPlay (glanceable alerts
  only; no video while driving), Siri Shortcuts.
```

---

## 4. App Privacy "nutrition label" (App Store Connect → App Privacy)

Declare honestly (matches `/privacy`):
- **Contact Info → Email Address** — Linked to identity · Used for **App Functionality**
  (account sign-in). Not used for tracking.
- **(Optional) Other Data → Other Data Types** — the Frigate connection you save; App
  Functionality, linked to identity, not for tracking.
- **Tracking:** No. **Data used to track you:** none.
- Everything else (camera video, push tokens) is App Functionality, not sold/shared.

---

## 5. DEPLOYMENT — domain & env (relay + website on your server)

The relay app serves BOTH the website and the API. Point your domain at it.

- DNS: `apexsight.app` → your relay container (Cloudflare Tunnel / reverse proxy, HTTPS).
- Env on the relay:
  - `APEX_PUBLIC_URL=https://apexsight.app`  (used in verification / reset email links)
  - `APEX_ADMIN_PASSWORD=…`  (admin GUI)
  - `APEX_SMTP_HOST/PORT/USER/PASSWORD/FROM`  (email verification + password reset)
  - `APEX_SESSION_HTTPS_ONLY=1` (default)
- App: set `RelayConfig.defaultURL` (native-ios/.../Notifications/RelayConfig.swift) to
  your production relay origin — `https://apexsight.app` if the API is served there, or
  keep `https://relay.plexserver525.com`. Both can point at the same container.
- Upload your APNs `.p8` + Key/Team/Bundle IDs in the relay admin (`/admin`).

`relay.plexserver525.com` and `apexsight.app` can both resolve to the same relay — the
app uses whatever `RelayConfig.defaultURL` is; the website uses the host it's served on.

---

## 6. Screenshots — shot list (6.7" + 6.1" required)

1. Live multi-camera wall (hero)
2. Single live view with controls
3. Review tab with a rich detection
4. A Live Activity / Dynamic Island incident (Lock Screen)
5. Notification settings (per-camera, quiet hours)
6. Widgets on the Home/Lock Screen (+ StandBy)

---

## 7. After it's live
- Tag the release; bump the build number for the next upload.
- Watch App Store Connect → Analytics + Crashes the first week.
```
