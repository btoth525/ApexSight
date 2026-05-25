# Apex Sight

**Apex Sight** is a native iOS mobile client for [Frigate NVR](https://frigate.video) — your self-hosted AI security camera system, now in your pocket.

---

## Features

### Live Monitoring
- **Real-time camera grid** — live snapshots refreshing every 2 seconds
- **Fullscreen streaming** — HLS video with pinch-to-zoom (1x–4x) and double-tap reset
- **Swipe between cameras** — Snapchat-style swipe navigation in fullscreen
- **Picture-in-Picture** — keep watching while using other apps
- **Camera Tour mode** — landscape slideshow that auto-cycles cameras, interrupts on alerts
- **Long-press context menu** — Go Live, View Events, or Copy Stream URL from any camera card

### Alerts & Events
- **Review tab** — full alert history grouped by date with severity badges
- **Inline clip preview** — tap any event thumbnail to play the clip looping in-place (no modal needed)
- **Event detail sheet** — full video clip playback, mark reviewed, share clip or snapshot
- **Explore tab** — visual event grid with similarity search

### Push Notifications
- **Real-time Frigate alerts** delivered as push notifications
- **Action buttons** directly from the notification: View Clip, Mark Reviewed, Go Live, Silence 30 min
- **Deep linking** — tapping a notification jumps straight to the camera or event

### AI Hub
- **Guard Mode** — arm/disarm Frigate's AI guard with one tap
- **AI Insights** — detection stats, label distribution, camera activity dashboard
- **VLM Triggers** — create custom Vision Language Model monitors with natural language prompts

### Native iOS Polish
- **Haptic feedback** throughout — light taps, heavy guard toggle, success/error pulses
- **Face ID / Touch ID** login support
- **Offline banner** — animated indicator when network drops, green confirmation when restored
- **Secure credential storage** via iOS Keychain
- **Dark mode** — pure dark UI optimized for nighttime monitoring

---

## Requirements

- iPhone running iOS 15+
- Self-hosted [Frigate NVR](https://frigate.video) instance (local or remote)
- Frigate authentication enabled

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | React Native + Expo (SDK 51) |
| Navigation | Expo Router (file-based) |
| Styling | NativeWind (Tailwind CSS) |
| State | Zustand + expo-secure-store |
| Video | expo-video (HLS) |
| Gestures | react-native-gesture-handler + reanimated |
| Notifications | expo-notifications |
| Auth | Cookie-based JWT + WebAuthn biometrics |
| Real-time | WebSocket (auto-reconnect) |
| Data fetching | SWR via useFrigateApi hook |

---

## Getting Started (Development)

### Prerequisites
- Node.js 18+
- Xcode 15+ (Mac required for iOS builds)
- Expo CLI

### Setup

```bash
git clone https://github.com/btoth525/ApexSight.git
cd ApexSight
npm install
npx expo prebuild --platform ios
open ios/ApexSight.xcworkspace
```

Run in iOS Simulator from Xcode, or archive for TestFlight distribution.

### Environment

No `.env` file needed. The server URL is configured at runtime in the app's login screen and Settings tab.

---

## Project Structure

```
app/
├── (auth)/login.tsx        # Login screen with biometric support
├── (tabs)/
│   ├── index.tsx           # Live camera grid
│   ├── review.tsx          # Alert review timeline
│   ├── explore.tsx         # Event search & similarity
│   ├── ai-hub.tsx          # Guard mode + AI insights + VLM triggers
│   └── settings.tsx        # Server config, notifications, account
└── camera-tour.tsx         # Landscape auto-tour mode

components/
├── camera/                 # CameraCard, CameraGrid, LivePlayer
├── events/                 # ReviewCard, EventCard, EventDetailSheet
├── ai/                     # GuardStatusCard, InsightsTab, TriggersTab
├── notifications/          # NotificationHandler
└── ui/                     # Skeleton, OfflineBanner

hooks/                      # useAuth, useBiometrics, useFrigateApi, useFrigateEvents
stores/                     # authStore, settingsStore (Zustand)
utils/                      # apiClient, haptics, labelUtil, timeUtil
```

---

## Distribution

Built and distributed via **TestFlight** / **App Store Connect**.

- Bundle ID: `com.brandontoth.apexsight`
- Platform: iOS only

---

## License

Private — all rights reserved.
