# ApexSight Push Companion (optional)

ApexSight works fully **without this**. Out of the box you get:

- **Real-time in-app alerts** via Frigate's stock WebSocket (`/ws`) — zero config.
- **Background alerts** via iOS Background App Refresh — zero config (best-effort, throttled by iOS).

This optional companion adds **instant push when the app is fully closed**. Stock Frigate has no APNs integration, so a small separate service is needed to forward Frigate alerts to Apple Push Notification service (APNs). It does **not** modify Frigate — it only subscribes to Frigate's MQTT `frigate/reviews` topic.

## How it works

```
Frigate (unmodified) ──MQTT frigate/reviews──▶ apns_notifier.py ──APNs──▶ iPhone (ApexSight)
```

The app renders the payload automatically: the notification extension downloads the snapshot and tapping deep-links to the review. You only supply the device token and an APNs auth key.

## Setup

### 1. Create an APNs Auth Key

In [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list):
- Create a new key with **Apple Push Notifications service (APNs)** enabled.
- Download the `.p8` file and note the **Key ID** (10 characters) and your **Team ID**.

### 2. Get your device token

In ApexSight: **Settings → Instant Push → enable** → copy the device token shown.

### 3. Run the companion

On any always-on host that can reach your MQTT broker:

```bash
pip3 install paho-mqtt pyjwt cryptography httpx

export APEX_APNS_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
export APEX_APNS_KEY_ID=XXXXXXXXXX        # 10-char Key ID from Apple Developer
export APEX_APNS_TEAM_ID=XXXXXXXXXX       # 10-char Team ID from Apple Developer
export APEX_BUNDLE_ID=com.your.bundle.id  # must match your app's bundle identifier
export APEX_DEVICE_TOKEN=<paste from app>
export APEX_FRIGATE_BASE_URL=https://frigate.example.com
export APEX_FRIGATE_TOKEN=<Frigate API token — only used to fetch the snapshot>
export APEX_MQTT_HOST=192.168.x.x         # your MQTT broker IP

python3 apns_notifier.py
```

> **Never commit the `.p8` file, device token, or Frigate token.** All secrets are read from environment variables only. `apns_notifier.py` ships with zero embedded credentials.

## Notification payload

The companion sends:

```json
{
  "aps": {
    "alert": { "title": "...", "body": "..." },
    "mutable-content": 1,
    "sound": "default"
  },
  "review_id": "1700000000.123-abcd",
  "camera": "front_door",
  "apex_url": "apex://review?id=1700000000.123-abcd",
  "snapshot_url": "https://frigate.example.com/api/events/<id>/snapshot.jpg",
  "frigate_token": "<token for the extension to fetch the snapshot>"
}
```

The notification service extension in the app downloads the snapshot and attaches it automatically. Tapping the notification deep-links to the review.

## Security notes

- The `.p8` APNs key and Frigate token should be treated as secrets — store them in a secrets manager or environment file with restricted permissions.
- The device token identifies your device to APNs; rotate it by toggling Instant Push off and on in Settings.
- This service runs on your own infrastructure. No data passes through any third-party servers.
