# ApexSight Native iOS

Native SwiftUI client for [Frigate NVR](https://frigate.video). Requires macOS + Xcode 15+ to build.

## Quick Start

```bash
brew install xcodegen   # one-time
cd native-ios
xcodegen generate
open ApexSightNative.xcodeproj
```

Select your device in Xcode and press **⌘R**.

## Signing

Open the Xcode project → Signing & Capabilities → set your Apple Developer team. Update `bundleIdPrefix` in `project.yml` to your own reverse-domain identifier before building for a real device or TestFlight.

## Architecture

| Component | Technology |
|---|---|
| UI | SwiftUI (iOS 17+) |
| Live video | AVPlayer + go2rtc HLS (fMP4) |
| Recorded clips | Direct MP4 via AVPlayer |
| Real-time events | URLSessionWebSocketTask → Frigate `/ws` |
| Auth | Frigate JWT — Cookie + Authorization header on all requests |
| Credentials | iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) |
| Background alerts | BGAppRefreshTask |
| Widgets | WidgetKit (Home Screen + Lock Screen) |
| Live Activities | ActivityKit (Lock Screen + Dynamic Island) |
| Notifications | UNUserNotificationCenter + UNNotificationServiceExtension |
| Project generation | XcodeGen (`project.yml`) |

## Targets

| Target | Bundle ID suffix | Purpose |
|---|---|---|
| ApexSightNative | `.native` | Main app |
| ApexSightWidgets | `.native.widgets` | WidgetKit + ActivityKit extension |
| ApexSightNotificationService | `.native.NotificationService` | Rich notification attachments |

All three targets share the app group `group.com.<your-prefix>.apexsight` for UserDefaults and snapshot cache.

## Stream URLs

Live HLS from go2rtc (proxied by Frigate):
```
GET {baseURL}/api/go2rtc/api/stream.m3u8?src={cameraName}&mp4
```
The valueless `&mp4` flag is required — it makes go2rtc output fMP4 segments that AVPlayer accepts.

Substream (network fallback after 3 consecutive failures):
```
GET {baseURL}/api/go2rtc/api/stream.m3u8?src={cameraName}_sub&mp4
```

## Build Validation

```bash
xcodegen generate
xcodebuild \
  -project ApexSightNative.xcodeproj \
  -scheme ApexSightNative \
  -destination 'generic/platform=iOS' \
  build
```
