# Aqara G410 Two-Way Audio — HA Setup

## Step 1: Test the protocol (run in HA terminal)

```bash
python3 /config/scripts/test_doorbell_audio.py 192.168.1.67
```

You should hear a 1 kHz beep through the doorbell speaker.
If you get "Cannot reach 192.168.1.67:54324" — check that your G410
firmware has LAN control enabled (Aqara app → Camera Settings → LAN Preview: ON).

---

## Step 2: Install aqara-doorbell custom integration via HACS

1. Open HA → HACS → Integrations → ⋮ → Custom Repositories
2. Add:
   - **Repository**: `https://github.com/absent42/aqara-doorbell`
   - **Category**: Integration
3. Search for "Aqara Doorbell" → Install → Restart HA
4. Settings → Devices & Services → Add Integration → "Aqara Doorbell"
5. Enter:
   - **Host**: `192.168.1.67`
   - **Username**: `674`
   - **Password**: `783`

After restart you'll see a new device with:
- `camera.aqara_doorbell_192_168_1_67` — RTSP video feed
- `event.aqara_doorbell_192_168_1_67_doorbell` — ring events
- Services: `aqara_doorbell.talk_start`, `aqara_doorbell.talk_stop`, `aqara_doorbell.talk_audio_file`

---

## Step 3: Test sending audio from HA

In Developer Tools → Services, call:

```yaml
service: aqara_doorbell.talk_audio_file
data:
  file_path: /media/test_tone.aac
```

Or record a greeting and play it:
```yaml
service: aqara_doorbell.talk_audio_file
data:
  file_path: /media/doorbell_greeting.aac
```

To generate a test AAC file in the HA terminal:
```bash
ffmpeg -f lavfi -i sine=frequency=1000:duration=2 \
  -c:a aac -profile:a aac_low -b:a 32k -ar 16000 -ac 1 \
  /media/test_tone.aac
```

---

## Step 4: Live two-way audio in the HA dashboard

Install the WebRTC Camera card (also via HACS):
1. HACS → Frontend → "WebRTC Camera" → Install
2. Add a card to your dashboard:

```yaml
type: custom:webrtc-camera
streams:
  - url: aqara_doorbell_192_168_1_67
    mode: webrtc
    media: video,audio,microphone
style: >
  video { aspect-ratio: 3/4; object-fit: fill; }
```

> IMPORTANT: use `url:` (the go2rtc stream name), NOT `entity:`.
> The stream name is `aqara_doorbell_` + IP with underscores.

This gives you full two-way audio in the browser on your home network.

---

## Step 5: Automation — ring → play greeting

```yaml
automation:
  alias: "Doorbell greeting"
  trigger:
    - platform: state
      entity_id: event.aqara_doorbell_192_168_1_67_doorbell
      attribute: event_type
      to: ring
  action:
    - delay: "00:00:01"  # brief pause after ring
    - service: aqara_doorbell.talk_audio_file
      data:
        file_path: /media/doorbell_greeting.aac
```
