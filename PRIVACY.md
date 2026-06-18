# ApexSight Privacy Policy

_Last updated: June 18, 2026_

ApexSight is a native iOS client for your own [Frigate](https://frigate.video) NVR.
It is **local-first**: it talks to servers **you** run and control. We — the
developers of ApexSight — do not operate a backend that receives your data, and
we do not collect, sell, or share any personal information.

## What ApexSight does *not* do

- **No accounts.** There is no ApexSight sign-up or login.
- **No analytics or telemetry.** The app contains no third-party tracking SDKs,
  advertising, or usage analytics.
- **No data sold or shared** with third parties for any purpose.
- **No tracking** across apps or websites.

## Information ApexSight handles (and where it stays)

- **Frigate server address & credentials.** Stored encrypted in the iOS
  Keychain on your device so the app can connect to your NVR. They are sent only
  to the Frigate server you configure.
- **Camera video, snapshots, and event metadata.** Streamed and fetched directly
  from your Frigate server for display. Cached copies (for widgets, the Live
  Activity, CarPlay, and Apple Watch) are stored locally on your devices in a
  shared app-group container.
- **Push notifications.** If you enable push alerts, your device's Apple Push
  Notification service (APNs) token and a pairing code are sent to the push
  relay **you** point the app at (the self-hosted ApexSight relay and your Home
  Assistant bridge). Alert text and snapshot images are delivered through APNs to
  show rich notifications. This infrastructure is operated by you, not by us.
- **Photos.** Used only to save camera clips you explicitly choose to download.
  The app only requests add-to-library access and never reads your library.
- **Face ID / Touch ID.** If you enable the optional app lock, biometric
  authentication happens entirely on-device through Apple's LocalAuthentication
  framework. ApexSight never receives your biometric data.

## Permissions

ApexSight requests only the permissions tied to a feature you use:

| Permission | Why |
| --- | --- |
| Local Network | Connect to Frigate on your LAN |
| Notifications | Deliver camera alerts |
| Photo Library (add only) | Save clips you download |
| Face ID / Touch ID | Optional app lock |

## Data retention & deletion

All ApexSight data lives on your devices and your servers. Removing data is fully
in your control:

- Sign out or delete the app to clear locally stored credentials and caches.
- Delete recordings/events on your Frigate server to remove that footage.

## Children's privacy

ApexSight is not directed at children and collects no personal information from
anyone.

## Changes

If this policy changes, the updated version will be posted here with a new "Last
updated" date.

## Contact

Questions about privacy: **brandontoth525@gmail.com**
