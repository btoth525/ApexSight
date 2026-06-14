# ApexSight Native — Xcode Setup

Complete guide to create the Xcode project and get to a TestFlight build.

---

## 1. Create Xcode Project

1. Open Xcode → **File → New → Project**
2. Choose **iOS → App**
3. Options:
   - **Product Name**: `ApexSight`
   - **Team**: Brandon Toth (3Q9ZUDN4QZ)
   - **Bundle Identifier**: `com.brandontoth.apexsight`
   - **Interface**: SwiftUI
   - **Language**: Swift
   - **Uncheck** "Include Tests" (add later)
4. Save to a folder of your choice (can be alongside this repo or inside `ios-native/`)

---

## 2. Add Source Files

Drag all files from `ios-native/Sources/` into Xcode's project navigator.
Make sure **"Copy items if needed"** is checked and they're added to the `ApexSight` target.

Required files:
```
Sources/
├── ApexSightApp.swift
├── ContentView.swift
├── Auth/
│   ├── AuthManager.swift
│   └── LoginView.swift
├── Cameras/
│   ├── CameraGridView.swift
│   ├── CameraCardView.swift
│   └── LiveStreamView.swift
├── Doorbell/
│   ├── DoorbellManager.swift
│   ├── DoorbellCallView.swift
│   └── WebRTCCallView.swift
├── Events/
│   └── ReviewView.swift
├── Settings/
│   └── SettingsView.swift
└── Utils/
    ├── FrigateAPI.swift
    └── DoorbellStream.swift
```

---

## 3. Configure Info.plist

Replace the default `Info.plist` content with `Resources/Info.plist.template`.
In Xcode: select `Info.plist` → right-click → Open As → Source Code → paste content.

Key entries that matter:
- `UIBackgroundModes`: `[voip, audio, fetch]`
- `NSMicrophoneUsageDescription` — required for mic permission
- `NSFaceIDUsageDescription` — required for Face ID
- `NSAppTransportSecurity → NSAllowsArbitraryLoads: true` — allows HTTP Frigate instances

---

## 4. Add Entitlements

1. Select the `ApexSight` target → **Signing & Capabilities** tab
2. Click **+ Capability** and add:
   - **Push Notifications**
   - **Background Modes** → check: **Voice over IP**, **Audio**, **Background fetch**
3. The entitlements file is auto-created. Open it (`.entitlements`) and add:
   ```xml
   <key>com.apple.developer.pushkit.voip</key>
   <true/>
   ```
   (The `aps-environment` key is auto-managed by Xcode when you enable Push Notifications)

---

## 5. Frameworks (all are system frameworks — no SPM packages needed)

In **Build Phases → Link Binary With Libraries**, verify these are linked (Xcode usually adds them automatically when you reference them in code, but check):

| Framework | Used for |
|---|---|
| `AVFoundation` | HLS playback, audio session |
| `AVKit` | `VideoPlayer` in events |
| `CallKit` | CallKit doorbell UI |
| `PushKit` | VoIP push (PushKit) |
| `LocalAuthentication` | Face ID |
| `WebKit` | WKWebView for WebRTC |
| `Security` | Keychain |

---

## 6. Signing

- Select your **Apple Developer team**: Brandon Toth / 3Q9ZUDN4QZ
- **Automatically manage signing**: ON
- Bundle ID must match: `com.brandontoth.apexsight`
  (This is the same bundle ID as the React Native app — same provisioning profile)

---

## 7. Build & Run

```
Xcode → Product → Run (⌘R)
```

Test on a real device for VoIP push and CallKit — the simulator doesn't support PushKit.

---

## 8. TestFlight Distribution

```
Xcode → Product → Archive
  → Distribute App
  → App Store Connect
  → Upload
```

Then in App Store Connect → TestFlight → add build to test group.

---

## Environment / Server Config

Default server URL is `https://frigate.plexserver525.com` — users can change it in Settings.

Key values (already hardcoded as defaults in `FrigateAPI.swift`):
- Base URL: stored in `UserDefaults` key `"frigate_base_url"`
- JWT token: stored in Keychain, service `"ApexSight"`, account `"frigate_token"`
- VoIP token: stored in Keychain, service `"ApexSight"`, account `"voip_push_token"`

---

## VoIP Push Token

After first launch on a real device, go to **Settings → Doorbell** in the app.
Copy the VoIP token and paste it into `/config/scripts/ring_doorbell.sh` on Home Assistant
(replacing the token in the `--token` argument).

Same APNs credentials as before:
- Key ID: `692KL4V524`
- Team ID: `3Q9ZUDN4QZ`
- Key path: `/config/apns/AuthKey_692KL4V524.p8`

---

## Two-Way Audio (Doorbell)

The mic button on the call screen connects to the Python audio proxy running on HA.
Make sure the proxy is running and the Cloudflare tunnel routes `/doorbell-audio` to port 8556.
See `frigate-integration/ha_doorbell_integration_setup.md` for full setup.

---

## What's Different from the React Native App

| | React Native (old) | SwiftUI (new) |
|---|---|---|
| Framework | Expo SDK 51 | Native SwiftUI |
| App size | ~80 MB | ~8 MB |
| CallKit | react-native-callkeep | Pure Swift CXProvider |
| PushKit | react-native-voip-push-notification | Pure Swift PKPushRegistry |
| Video | WebView (WKWebView running go2rtc HTML) | AVPlayer (HLS) + WKWebView (WebRTC call) |
| Mic | getUserMedia in WKWebView JS | WKWebView JS (same approach, same proxy) |
| Auth | expo-secure-store | iOS Keychain directly |
| Navigation | Expo Router (file-based) | SwiftUI NavigationStack + TabView |
| Cold start | ~2–3s | <0.5s |
