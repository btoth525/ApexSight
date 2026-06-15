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

## Part B — Host the relay (on your home server)

```bash
cd push-relay
cp .env.example .env
# edit .env: set APEX_ADMIN_USERNAME + APEX_ADMIN_PASSWORD
docker compose up -d          # publishes the relay on port 3421
```

1. **Expose it** — you already run a Cloudflare Tunnel / reverse proxy, so just
   point a public hostname like `relay.plexserver525.com` at `http://<this-host>:3421`.
   (If your tunnel runs in Docker, attach the relay to its network and route to
   `http://relay:3421` — see the commented `networks:` block in
   `push-relay/docker-compose.yml`.)
2. Open **`https://relay.plexserver525.com/admin`**, sign in with your
   **username + password**. (The login is brute-force protected: 5 wrong tries
   from an IP → locked out for 15 minutes.)
3. **Settings → upload your `.p8`**, paste **Key ID** + **Team ID** (Bundle ID is
   pre-filled). Save. The dashboard should show **APNs ● Configured**.

> Your `.p8` lives only in the relay's `/data` volume — never in the app or this repo.

---

## Part C — Pair your phone (zero steps for users)

Both the relay URL **and** a shared household pairing code (`APEX-PLEX-5250`) are
**baked into the app**, so for your shared-camera setup users don't type anything.

1. In **ApexSight → Settings → Instant Push**: toggle **Enable instant push**.
   The status dot turns **🟢 Connected** and it shows **"Paired automatically"** —
   that's it. (🔴 means the relay isn't reachable yet.)
2. On the relay dashboard, enter `APEX-PLEX-5250` and click **Send test** — every
   registered phone should buzz. (If it fails with `BadDeviceToken` on a Debug
   build from Xcode, set the relay Environment to **Force sandbox** and retry.)

> The shared code lives in `RelayConfig.swift` (app) and the add-on's
> `config.yaml`. Anyone who installs the app + enables push will get these alerts —
> intended for sharing your own cameras. Someone with their own Frigate can tap
> **Join household** in the app to use a private code instead.
>
> Make sure your relay is served at **https://relay.plexserver525.com** (point a
> Cloudflare Tunnel / proxy public hostname at `http://<host>:3421`).

---

## Part D — Forward alerts from Home Assistant

Install the **ApexSight Push Bridge** add-on (full guide:
`homeassistant-addon/README.md`). Two ways:

- **Local (fastest, for yourself):** copy `homeassistant-addon/apexsight-push-bridge/`
  into your HA `/addons` folder (via the Samba/File-editor add-on or `scp`), then
  HA → **Settings → Add-ons → Add-on Store → ⟳** → it appears under **Local add-ons**.
- **Repository (for testers):** copy `repository.yaml` + the `apexsight-push-bridge/`
  folder into a dedicated public GitHub repo (folders must sit at the repo root),
  then in HA → **Add-on Store → ⋮ → Repositories**, add that repo URL.

Then open the add-on → **Configuration**. For the shared-camera setup, `relay_url`
and `pairing_code` are **already pre-filled** — you only set:
- `frigate_base_url`: a URL your phone can reach Frigate at (for the snapshot/GIF)
- `alerts_only`: `true` (default)

**Start** the add-on → trigger motion → instant rich notification, app closed. 🎉

> You set up this **one** add-on (your Home Assistant). Your users do **nothing** —
> their app auto-registers to the shared code on launch.

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
