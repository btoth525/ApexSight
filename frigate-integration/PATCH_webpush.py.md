# Patch: `frigate/comms/webpush.py`

Three edits to integrate Expo Push alongside the existing VAPID WebPush.

---

## Edit 1 — Add imports at the top of the file

```python
from frigate.comms.expo_push import (
    ExpoPushClient,
    extract_expo_token,
    is_expo_token,
)
```

## Edit 2 — In `WebPushClient.__init__()`, create an Expo client and route Expo tokens to it

Find the block that loads tokens from the database (it iterates `User.notification_tokens` and creates `WebPusher` instances). Replace it with:

```python
# Initialize Expo Push client for native mobile apps (iOS/Android)
self.expo_push = ExpoPushClient(stop_event)

users: list[dict[str, Any]] = (
    User.select(User.username, User.notification_tokens).dicts().iterator()
)
for user in users:
    self.web_pushers[user["username"]] = []
    for sub in user["notification_tokens"]:
        if is_expo_token(sub):
            token = extract_expo_token(sub)
            if token:
                self.expo_push.register_token(user["username"], token)
        else:
            self.web_pushers[user["username"]].append(WebPusher(sub))
```

## Edit 3 — In every send method (`send_alert`, `send_trigger`, `send_camera_monitoring`), also call the Expo client

After the existing loop that calls `pusher.send(...)`, add a call to `self.expo_push.send(...)`.

Example — inside `send_alert()`:

```python
# Existing WebPusher send loop above this …

# Send to native mobile apps via Expo Push (lock-screen rich notifications)
image_url = (
    f"{self.config.tls.external_url}/api/notification-thumb/{review.id}"
    if hasattr(self.config, "tls") and self.config.tls.external_url
    else f"/api/notification-thumb/{review.id}"
)
self.expo_push.send(
    title=title,
    body=body,
    data={
        "type": "alert",
        "review_id": str(review.id),
        "camera": review.camera,
    },
    image_url=image_url,
    category="FRIGATE_ALERT",
)
```

Repeat for `send_trigger` (use event thumb URL, category `FRIGATE_TRIGGER`) and `send_camera_monitoring` (category `FRIGATE_GUARD`).

---

**That's it on the WebPush side.** The existing `/notifications/register` endpoint already accepts arbitrary `sub` objects, so when the mobile app POSTs `{ sub: { type: "expo", token: "ExponentPushToken[...]" } }`, it gets appended to `User.notification_tokens` as JSON. On the next Frigate restart (or when the client re-initializes), the Expo token is detected and routed correctly.

For **immediate effect without restart**, also add this at the end of `register_notifications()` in `frigate/api/notification.py`:

```python
# If this is an Expo token, register it live with the running webpush client
try:
    from frigate.comms.expo_push import extract_expo_token, is_expo_token
    if is_expo_token(sub):
        token = extract_expo_token(sub)
        if token and hasattr(request.app, "webpush"):
            request.app.webpush.expo_push.register_token(username, token)
except Exception:
    pass
```
