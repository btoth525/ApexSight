# Patch: `frigate/comms/webpush.py`

Three edits to integrate Expo Push alongside the existing VAPID WebPush.

---

## Edit 1 — Add imports at the top of the file

```python
from frigate.comms.expo_push import (
    ExpoPushClient,
    extract_base_url,
    extract_expo_token,
    is_expo_token,
)
```

---

## Edit 2 — In `WebPushClient.__init__()`, create the Expo client and route tokens

Find the block that loads tokens from the database and creates `WebPusher` instances.
Replace it with:

```python
# Native mobile push (iOS/Android) via Expo gateway → APNs/FCM
self.expo_push = ExpoPushClient(stop_event)

users: list[dict[str, Any]] = (
    User.select(User.username, User.notification_tokens).dicts().iterator()
)
for user in users:
    self.web_pushers[user["username"]] = []
    for sub in user["notification_tokens"]:
        if is_expo_token(sub):
            token = extract_expo_token(sub)
            base_url = extract_base_url(sub)
            if token:
                self.expo_push.register_token(user["username"], token, base_url)
        else:
            self.web_pushers[user["username"]].append(WebPusher(sub))
```

---

## Edit 3 — In `send_alert()`, also send via Expo Push with the snapshot image

After the existing WebPusher send loop, add:

```python
# Send to native mobile apps — image URL built from the app's registered base_url
# so the Cloudflare tunnel URL is used automatically (no hardcoding needed)
self.expo_push.send_alert(
    title=title,
    body=body,
    data={
        "type": "alert",
        "review_id": str(review.id),
        "camera": review.camera,
    },
    thumb_id=str(review.id),
    category="FRIGATE_ALERT",
)
```

For `send_trigger()`, add after its WebPusher loop:

```python
self.expo_push.send_alert(
    title=title,
    body=body,
    data={"type": "trigger", "camera": getattr(trigger, "camera", "")},
    thumb_id=getattr(trigger, "id", None),
    category="FRIGATE_TRIGGER",
)
```

For `send_camera_monitoring()`, add after its WebPusher loop:

```python
self.expo_push.send_alert(
    title=title,
    body=body,
    data={"type": "guard", "camera": getattr(event, "camera", "")},
    thumb_id=getattr(event, "id", None),
    category="FRIGATE_GUARD",
)
```

---

## How the Cloudflare URL gets used (no hardcoding)

When the iOS app registers, it sends:
```json
{ "sub": { "type": "expo", "token": "ExponentPushToken[...]", "base_url": "https://frigate.yourdomain.com" } }
```

The `base_url` is stored with the token. When Frigate fires a notification it builds:
```
https://frigate.yourdomain.com/api/notification-thumb/{review_id}
```

That URL is public (no auth required) so iOS can fetch the snapshot image even on the
lock screen. Works from anywhere because it goes through Cloudflare.
