# ApexSight Instant Push — End-to-End Setup

This is the full path to **instant notifications when the app is closed**, for you
and for anyone who downloads ApexSight. You set up the relay **once**; each tester
just installs one Home Assistant add-on and pastes a code.

```
 Apple Developer (.p8)  ─upload→  PUSH RELAY (you host, holds the key)
                                        ▲                    │ signs + sends
 each tester's iPhone ─register code────┘                    ▼
 each tester's Home Assistant ─forward alerts──────────▶  Apple APNs → iPhone
        (ApexSight Push Bridge add-on, no secrets)
```

---

## Part A — Get your Apple APNs key (.p8) — one time, ~5 minutes

1. Go to **developer.apple.com → Certificates, Identifiers & Profiles → Keys**.
2. Click **➕**. Name it `ApexSight APNs`. Tick **Apple Push Notifications service (APNs)**. **Continue → Register**.
3. **Download** the `AuthKey_XXXXXXXXXX.p8` (you can only download it once — keep it safe). The `XXXXXXXXXX` is your **Key ID**.
4. Find your **Team ID** under **Membership** (10 characters).

You now have: the `.p8` file, a **Key ID**, and a **Team ID**. That's everything the relay needs.

---

## Part B — Host the relay (on your home server, via Cloudflare Tunnel)

```bash
cd push-relay
cp .env.example .env
# edit .env: set APEX_ADMIN_PASSWORD, and CLOUDFLARE_TUNNEL_TOKEN (Part B.2)
docker compose up -d
```

1. **Cloudflare Tunnel** (free, no port-forwarding): Cloudflare **Zero Trust → Networks → Tunnels → Create**. Add a **Public Hostname** like `push.yourdomain.com` → service `http://relay:8080`. Copy the tunnel **token** into `CLOUDFLARE_TUNNEL_TOKEN` in `.env`, then `docker compose up -d`.
2. Open **`https://push.yourdomain.com/admin`**, sign in with `APEX_ADMIN_PASSWORD`.
3. **Settings → upload your `.p8`**, paste **Key ID** + **Team ID** (Bundle ID is pre-filled). Save. The dashboard should show **APNs ● Configured**.

> Your `.p8` lives only in the relay's `/data` volume — never in the app or this repo.

---

## Part C — Pair your phone

1. (Before shipping to testers) set `RelayConfig.defaultURL` in
   `native-ios/Sources/ApexSight/Notifications/RelayConfig.swift` to your relay
   URL so every install is pre-pointed. For your own testing you can skip this and
   type it in the app.
2. In **ApexSight → Settings → Instant Push**: toggle **Enable instant push**,
   confirm the **Relay URL**, and note the **Pairing Code** (e.g. `APEX-7F3K-2Q9P`).
   The status should turn to **Registered ✓**.
3. On the relay dashboard, enter that code and click **Send test** — your phone
   should buzz. (If it fails with `BadDeviceToken` on a Debug build from Xcode, set
   the relay Environment to **Force sandbox** and retry.)

---

## Part D — Forward alerts from Home Assistant

1. HA → **Settings → Add-ons → Add-on Store → ⋮ → Repositories**, add
   `https://github.com/btoth525/apexsight`.
2. Install **ApexSight Push Bridge**. In its **Configuration**:
   - `relay_url`: `https://push.yourdomain.com`
   - `pairing_code`: the code from the app
   - `frigate_base_url`: a URL your phone can reach Frigate at (for the snapshot/GIF)
   - `alerts_only`: `true`
3. **Start** the add-on. Trigger motion → instant rich notification, app closed. 🎉

---

## How each tester onboards (after you've done A–B once)

1. Install ApexSight → enable Instant Push → copy their **own** pairing code.
2. Install the **ApexSight Push Bridge** add-on → paste relay URL + their code + their Frigate URL.

That's it — no token collection, no Apple account for testers, no secrets shared.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Dashboard: "Not configured" | Upload the `.p8` and set Key/Team IDs in Settings. |
| `BadDeviceToken` | Wrong APNs environment — set relay Environment to match the build (Auto usually works; Force sandbox for Xcode Debug). |
| No image in the notification | `frigate_base_url` must be reachable from the phone; if Frigate auth is on, sign into Frigate in the app (the extension reuses that token). |
| "no devices for pairing code" | The phone hasn't registered yet, or the code in the add-on doesn't match the app. |
| Nothing arrives | Check the add-on logs (it logs each forwarded review) and the relay is reachable at `https://…/healthz`. |
