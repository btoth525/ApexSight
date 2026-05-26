# Expo Push integration — Apex Sight + Frigate

Adds true background push notifications (lock-screen, rich snapshot preview, works when the iOS app is fully killed) to your Frigate fork.

## Architecture

```
iPhone app (closed/killed)
        ▲
        │ APNs push
        │
   Apple APNs
        ▲
        │ HTTPS POST
        │
  Expo Push gateway
        ▲
        │ HTTPS POST (free, no signing)
        │
   Frigate (Unraid)
   └─ ExpoPushClient
   └─ User.notification_tokens
```

The Expo gateway eliminates the need to manage APNs certificates and HTTP/2 signing on the server side. It's free and used in production by thousands of apps.

---

## Step 1 — Patch your Frigate fork

```bash
cd /path/to/your/frigate-fork
git checkout claude/ai-search-frigate-9mNG1

# 1. Copy in the new Expo Push client
cp /path/to/ApexSight/frigate-integration/expo_push.py \
   frigate/comms/expo_push.py

# 2. Manually apply the patches in:
#    frigate-integration/PATCH_webpush.py.md
#    (3 small edits to frigate/comms/webpush.py)

# 3. Commit
git add frigate/comms/expo_push.py frigate/comms/webpush.py frigate/api/notification.py
git commit -m "Add Expo Push support for native mobile apps"
git push origin claude/ai-search-frigate-9mNG1
```

## Step 2 — Build the GHCR image

See `PATCH_ci.yml.md`. Easiest: go to Actions tab → run CI workflow manually on your branch.

## Step 3 — Update Unraid container

Edit your Frigate Docker template, set image to:
```
ghcr.io/btoth525/frigate:<short-sha>-amd64
```
Apply → done.

## Step 4 — Set up the Apex Sight app for Expo Push

The app already has the registration hook (`useExpoPushRegistration`). It needs an **EAS project ID** to get a valid push token from Expo.

### One-time EAS setup (free)

```bash
cd /Users/brandon/Documents/ApexSight
npm install -g eas-cli       # if not already
eas login                    # use your Expo account (free signup)
eas init                     # creates project, writes projectId into app.json
```

That's it. `eas init` adds this to `app.json`:
```json
"extra": { "eas": { "projectId": "..." } }
```

Now on the next app launch, the hook automatically:
1. Asks Expo for a push token
2. POSTs it to `/notifications/register` on your Frigate
3. Frigate stores it
4. Next alert → Frigate sends to Expo → Apple → your phone (even when killed)

## Step 5 — Verify

1. **Server logs:** `docker logs frigate | grep "Expo Push"` — should show `Registered Expo Push token for admin: ExponentPushToken[…]`
2. **Trigger a motion alert** on a camera
3. **Lock your iPhone, close the app fully** (swipe up to kill it)
4. Wait for next alert — notification should pop on lock screen with snapshot image

## Troubleshooting

- **No `Registered Expo Push token` log line** → app isn't sending the token. Check that `eas init` ran successfully and `app.json` has the `projectId`. Make sure notifications permission is granted.
- **Token registers but no notifications fire** → check Frigate's webpush.py patches actually call `self.expo_push.send(...)` in the send methods.
- **"DeviceNotRegistered" errors in Frigate logs** → token was invalidated (you reinstalled the app or revoked notifications). The client auto-removes invalid tokens; just relaunch the app to register a new one.
- **Notifications work when app is open but not when killed** → that means local notifications work but Expo Push isn't firing. Check the path Frigate → Expo with: `curl -X POST https://exp.host/--/api/v2/push/send -H "Content-Type: application/json" -d '[{"to":"ExponentPushToken[YOUR_TOKEN]","title":"Test","body":"From curl"}]'`

---

## Files in this folder

| File | Purpose |
|---|---|
| `expo_push.py` | Drop-in Expo Push client for Frigate (`frigate/comms/expo_push.py`) |
| `PATCH_webpush.py.md` | 3 edits to integrate it into existing WebPushClient |
| `PATCH_ci.yml.md` | Enable GHCR Docker builds from your branch |
| `README.md` | This file |
