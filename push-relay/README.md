# ApexSight Push Relay

A small self-hosted server that turns Frigate alerts into **instant iOS push
notifications** — even when the ApexSight app is fully closed. It holds your
Apple APNs key, registers your devices, and is the one piece every household's
Home Assistant addon forwards alerts to.

```
 iPhone (ApexSight)                    Your home (Home Assistant)
        │  register token + code              │  Frigate → MQTT frigate/reviews
        ▼                                      ▼
 ┌──────────────────┐   /v1/notify    ┌────────────────────────┐
 │  PUSH RELAY (this)│◀───────────────│  ApexSight Push Bridge  │
 │  holds your .p8   │                │  (HA addon, no secrets) │
 └────────┬─────────┘                 └────────────────────────┘
          │ signed APNs push
          ▼
   Apple APNs ──▶ your iPhone shows the rich GIF alert
```

**Why a relay?** Apple only accepts pushes signed with *your* `.p8` key, which
must never be handed to testers. So one relay (yours) holds the key; every
tester just runs the bridge addon and pastes a pairing code. No Apple secret
ever leaves this server.

## What you need

- A machine that runs Docker (your Home Assistant host / home server is fine).
- A **paid Apple Developer account** and an **APNs Auth Key** (`.p8`) — the web
  GUI walks you through creating it.
- A free **Cloudflare Tunnel** (so the relay is reachable over HTTPS without
  opening any ports). Any HTTPS reverse proxy works too.

## Setup

```bash
cd push-relay
cp .env.example .env          # set APEX_ADMIN_PASSWORD + your Cloudflare token
docker compose up -d
```

1. **Cloudflare Tunnel** — in Cloudflare Zero Trust → Networks → Tunnels, create
   a tunnel, add a public hostname like `push.yourdomain.com` routing to
   `http://relay:8080`, and copy the tunnel **token** into `CLOUDFLARE_TUNNEL_TOKEN`
   in `.env`. (`docker compose up -d` starts both the relay and `cloudflared`.)

2. **Upload your key** — open `https://push.yourdomain.com/admin`, sign in with
   `APEX_ADMIN_PASSWORD`, go to **Settings**, and:
   - Upload the `.p8` (the page has step-by-step instructions to create one).
   - Paste the **Key ID** and **Team ID**. Bundle ID is pre-filled.
   - Leave Environment on **Auto**. Save.

3. **Point the app at the relay** — in ApexSight → Settings → Instant Push, set
   the Relay URL to `https://push.yourdomain.com`, toggle Instant Push on, and
   copy the **pairing code** it shows.

4. **Install the bridge addon** at each home (see `../homeassistant-addon/`) and
   paste in the relay URL + pairing code.

5. **Test** — on the relay Dashboard, enter your pairing code and click *Send
   test*. Your phone should buzz.

## HTTP API (used by the app + bridge)

| Method | Path             | Body                                                            |
|--------|------------------|-----------------------------------------------------------------|
| POST   | `/v1/register`   | `{device_token, pairing_code, environment, platform}`           |
| POST   | `/v1/unregister` | `{device_token}`                                                |
| POST   | `/v1/notify`     | `{pairing_code, title, body, camera, review_id, apex_url, snapshot_url, thumbnail_url, frigate_token}` |
| GET    | `/healthz`       | —                                                               |

## Security notes

- The `.p8`, Key ID and Team ID live only in the `/data` Docker volume (uploaded
  via GUI) — never in this repo or the app.
- The pairing code is the shared secret between a household's phones and its
  bridge; codes are random and the API is rate-limited per IP.
- APNs device tokens reported as gone (410 / Unregistered) are auto-pruned.
- Run behind HTTPS only (Cloudflare Tunnel handles TLS).
