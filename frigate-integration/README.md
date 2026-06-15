# ApexSight Push Companion (optional)

ApexSight works fully **without** this. It already gives you:

- **Real-time alerts in-app** via Frigate's stock WebSocket (`/ws`) — no setup.
- **Background alerts** via iOS Background App Refresh — no setup (best-effort, throttled by iOS).

This optional companion adds **instant push when the app is fully closed**. Stock
Frigate only speaks WebPush (for browsers), so a tiny separate service is needed to
forward Frigate alerts to Apple Push Notification service (APNs). This service does
**not** modify Frigate — it only subscribes to Frigate's MQTT `frigate/reviews` topic.

## How it fits together

```
Frigate (unmodified) ──MQTT frigate/reviews──▶ apns_notifier.py ──APNs──▶ iPhone (ApexSight)
```

The app already renders the payload: the notification service extension downloads the
snapshot, and tapping deep-links to the review. You only provide the device token and
an APNs auth key.

## One-time setup

1. **Apple Developer → Keys**: create an APNs Auth Key, download the `.p8`. Note the
   **Key ID** (10 chars) and your **Team ID** (`3Q9ZUDN4QZ`).
2. **In ApexSight**: Settings → Instant Push → enable → **Copy** the device token.
3. Run the companion (Python 3) on any always-on host that can reach your MQTT broker:

```bash
pip3 install paho-mqtt pyjwt cryptography httpx
export APEX_APNS_KEY_PATH=/secure/AuthKey_XXXXXXXXXX.p8
export APEX_APNS_KEY_ID=XXXXXXXXXX
export APEX_APNS_TEAM_ID=3Q9ZUDN4QZ
export APEX_BUNDLE_ID=com.brandontoth.apexsight.native
export APEX_DEVICE_TOKEN=<paste from the app>
export APEX_FRIGATE_BASE_URL=https://frigate.example.com
export APEX_FRIGATE_TOKEN=<a Frigate API token, used only to fetch the snapshot>
export APEX_MQTT_HOST=192.168.1.10
python3 apns_notifier.py
```

> Secrets are read from the environment only. **Never commit the `.p8`, device token,
> or Frigate token.** `apns_notifier.py` ships with zero embedded credentials.

## Payload contract (already consumed by the app)

```json
{
  "aps": { "alert": { "title": "...", "body": "..." }, "mutable-content": 1, "sound": "default" },
  "review_id": "1700000000.123-abcd",
  "camera": "front_door",
  "apex_url": "apex://review?id=1700000000.123-abcd",
  "snapshot_url": "https://frigate.example.com/api/review/<id>/preview",
  "frigate_token": "<token used by the extension to fetch the snapshot>"
}
```

`apns-topic` must be `com.brandontoth.apexsight.native` and `apns-push-type: alert`.
