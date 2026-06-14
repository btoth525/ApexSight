# ApexSight — Handoff Document

**Branch:** `claude/busy-feynman-O0rIC`
**Repo:** `btoth525/apexsight`
**Date:** 2026-06-14

---

## What ApexSight Is

Expo SDK 51 React Native app (iOS) that wraps Frigate NVR. Key features:
- Browses Frigate cameras in a full-screen WebView
- **CallKit doorbell**: Aqara G410 rings the iPhone like a real phone call via Apple VoIP push → PushKit → CallKit, even from a locked/killed state
- When answered, shows a live WebRTC camera feed

---

## Environment

| Thing | Value |
|---|---|
| Frigate URL | `https://frigate.plexserver525.com` (Cloudflare tunnel) |
| Frigate LAN | `192.168.1.204:5000` |
| Doorbell | Aqara G410 at `192.168.1.67:8554` |
| Doorbell RTSP creds | user `674` / pass `783` |
| go2rtc stream name | `doorbell_twoway` (ch1 main stream, always-on via Frigate record) |
| VoIP push token | `f84b714a3cbe08c45e7a7066a623f66f1776eec5e4ef7282d2eac2ee3540b60b` |
| APNs Key ID | `692KL4V524` |
| APNs Team ID | `3Q9ZUDN4QZ` |
| APNs p8 path on HA | `/config/apns/AuthKey_692KL4V524.p8` |
| Bundle ID | `com.brandontoth.apexsight` |
| App version | 2.0.2 build 5 (needs rebuild for latest changes) |

---

## Architecture

```
Doorbell pressed
  → HA automation (binary_sensor.door_bell_ring_occupancy → state on)
    → shell_command: ring_doorbell.sh
      → voip_push.py → Apple APNs (HTTP/2 via curl) → VoIP push
        → PushKit wakes app
          → useDoorbellCall.ts → RNCallKeep.displayIncomingCall()
            → Native CallKit screen
              → [pre-warm] hidden 1×1 WebView starts WebRTC handshake
                → User answers → /doorbell-call?camera=doorbell_twoway
                  → Full-screen WebView → go2rtc WebRTC
                    → Video from doorbell
```

---

## Key Files

### App

| File | Purpose |
|---|---|
| `app/_layout.tsx` | Root layout — mounts pre-warm WebView on VoIP push for fast video startup |
| `app/doorbell-call.tsx` | Full-screen call screen — WebRTC video + mic toggle button (two-way audio) |
| `hooks/useDoorbellCall.ts` | VoIP push registration, CallKit events, pre-warm callback |
| `utils/doorbellStream.ts` | `buildWsUrl()`, `buildAudioWsUrl()`, `buildWebRTCHtml()` — shared WebRTC + talkback JS |
| `stores/authStore.ts` | Zustand store — token, baseUrl, isLoading |

### Frigate Integration

| File | Purpose |
|---|---|
| `frigate-integration/voip_push.py` | Sends VoIP push to APNs via `curl --http2` (APNs requires HTTP/2) |
| `frigate-integration/ha_doorbell_automation.yaml` | HA automation + shell_command config |
| `frigate-integration/test_doorbell_audio.py` | **Run this first** — sends 1 kHz tone to doorbell speaker to test the Aqara protocol |
| `frigate-integration/doorbell_audio_ws.py` | Python WebSocket proxy for two-way audio (phone mic → doorbell speaker) |
| `frigate-integration/ha-addon/` | Local HA add-on packaging of the audio proxy |
| `frigate-integration/ha_doorbell_integration_setup.md` | Step-by-step HA two-way audio setup guide |
| `frigate-integration/cloudflared_config.yaml` | Cloudflare tunnel ingress rules to route `/doorbell-audio` to port 8556 |

---

## WebRTC Details

**go2rtc WebSocket path:** `/live/webrtc/api/ws?src=doorbell_twoway&token=<jwt>`

**go2rtc 2.x signaling protocol** (NOT standard WebRTC):
```json
send:    { "type": "webrtc/offer",     "value": "<sdp string>" }
receive: { "type": "webrtc/answer",    "value": "<sdp string>" }
receive: { "type": "webrtc/candidate", "value": "<candidate>\n<mlineIndex>" }
send:    { "type": "webrtc/candidate", "value": "<candidate string>\n0" }
```

**Why injected HTML instead of URL:** Frigate 0.14+ returns 403 on `/api/go2rtc/webrtc` for non-admin users. We inject custom WebRTC HTML directly into the WebView — bypasses the 403 entirely.

**ICE/port config** (in frigate.yaml):
```yaml
go2rtc:
  webrtc:
    candidates:
      - 192.168.1.204:8555
      - stun:8555
```
Port 8555 TCP+UDP must be forwarded on router to 192.168.1.204.

**Always-on stream:** Frigate's `record` input for the doorbell camera uses `rtsp://127.0.0.1:8554/doorbell_twoway` so go2rtc keeps the RTSP connection to the camera open 24/7 → instant video when call is answered.

---

## Two-Way Audio Status

**Current state:** Video works. Audio receive (hear visitor) may or may not work depending on G410 RTSP stream having an audio track.

**Two-way audio approach:** The Aqara G410 uses a **proprietary protocol** — NOT standard RTSP backchannel:
- TCP `192.168.1.67:54324` — control (START_VOICE, STOP_VOICE, HEARTBEAT every 5s)
- UDP `192.168.1.67:54323` — RTP audio (AAC-LC ADTS, 16kHz, mono, 32kbps)
- Packet format: `Magic(0xFEEF) | Type(1B) | PayloadLen(2B) | Payload(N) | CRC-16/KERMIT(2B)`

**App mic button:** Already implemented in `doorbell-call.tsx` — tap mic button → injects JS into WebView to call `getUserMedia` → streams PCM-16LE to `wss://frigate.plexserver525.com/doorbell-audio?token=<jwt>` → Python proxy encodes via ffmpeg → sends RTP UDP to doorbell.

**What's NOT done yet:**
1. Protocol not verified on THIS specific G410 unit yet
2. HA audio proxy (`doorbell_audio_ws.py`) not deployed and running
3. Cloudflare tunnel not updated to route `/doorbell-audio`
4. App not rebuilt with mic button changes

---

## Immediate Next Steps (in order)

### 1. Verify two-way audio works on the G410

SSH into HA and run:
```bash
cp /path/to/test_doorbell_audio.py /config/scripts/
python3 /config/scripts/test_doorbell_audio.py 192.168.1.67
```
You should hear a 1 kHz beep through the doorbell speaker. If you get "Cannot reach 192.168.1.67:54324" → enable LAN control in Aqara app (Camera Settings → LAN Preview: ON).

### 2. Install aqara-doorbell HACS integration for HA dashboard testing

1. HACS → Integrations → ⋮ → Custom Repositories
2. Add `https://github.com/absent42/aqara-doorbell` as Integration
3. Install → Restart HA
4. Add Integration → "Aqara Doorbell" → IP `192.168.1.67`, user `674`, pass `783`

### 3. Test live two-way in browser

Install WebRTC Camera card via HACS frontend, add dashboard card:
```yaml
type: custom:webrtc-camera
streams:
  - url: aqara_doorbell_192_168_1_67
    mode: webrtc
    media: video,audio,microphone
```

### 4. Once HA two-way works, deploy the audio proxy

**Option A — HA Add-on (recommended):**
```bash
mkdir -p /config/addons/apex_doorbell_audio
# Copy files from frigate-integration/ha-addon/ into it
# HA UI: Settings → Add-ons → Add-on Store → ⋮ → Check for updates
# Configure: doorbell_ip=192.168.1.67, frigate_token=<jwt>
# Start add-on
```

**Option B — Direct script:**
```bash
pip3 install websockets
DOORBELL_IP=192.168.1.67 FRIGATE_TOKEN=<jwt> python3 /config/scripts/doorbell_audio_ws.py &
```

### 5. Update Cloudflare tunnel

Edit cloudflared config (see `frigate-integration/cloudflared_config.yaml`):
```yaml
ingress:
  - hostname: frigate.plexserver525.com
    path: /doorbell-audio
    service: ws://localhost:8556
  - hostname: frigate.plexserver525.com
    service: http://localhost:5000
```
```bash
systemctl restart cloudflared
```

### 6. Rebuild app

```bash
cd ~/ApexFinalApp && git pull && npm install
npx expo prebuild --platform ios --clean
# Xcode → Product → Archive → TestFlight
```

---

## Known Issues / Things to Watch

- **VoIP token is permanent** — stored in SecureStore, doesn't change between builds
- **Cold start auth race** — fixed by waiting for `!isLoading` before mounting WebRTC WebView
- **go2rtc Docker ICE** — without `webrtc.candidates` config, Docker hides LAN IP and ICE fails (black screen). Config already set.
- **APNs requires HTTP/2** — `voip_push.py` uses `curl --http2` subprocess, not Python's http.client
- **Cloudflare handles WebSocket signaling** — WebRTC media travels direct on port 8555 (UDP), not through the tunnel

---

## Build Command Reference

```bash
# Full clean rebuild
cd ~/ApexFinalApp
git pull
npm install
npx expo prebuild --platform ios --clean
open ios/Apex.xcworkspace
# Xcode: Product → Archive → Distribute → TestFlight

# Test VoIP push manually
python3 /config/scripts/voip_push.py \
  --token "f84b714a3cbe08c45e7a7066a623f66f1776eec5e4ef7282d2eac2ee3540b60b" \
  --key-id "692KL4V524" \
  --team-id "3Q9ZUDN4QZ" \
  --key-path "/config/apns/AuthKey_692KL4V524.p8" \
  --camera "doorbell_twoway" \
  --caller "Front Door"
```
