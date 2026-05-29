#!/usr/bin/env python3
"""
Quick test: plays a 3-second 1 kHz tone through the Aqara G410 doorbell speaker.
Run from ANY machine on the same LAN as the doorbell (e.g. HA terminal).

Requirements: Python 3.8+  and  ffmpeg installed
  pip3 install websockets  (NOT required for this test)

Usage:
  python3 test_doorbell_audio.py [doorbell_ip]
  python3 test_doorbell_audio.py 192.168.1.67
"""

import socket
import struct
import subprocess
import sys
import threading
import time

DOORBELL_IP  = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.67"
CTRL_PORT    = 54324
AUDIO_PORT   = 54323
DURATION_SEC = 3


# ── Aqara control protocol ────────────────────────────────────────────────────

def _crc16_kermit(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if (crc & 1) else crc >> 1
    return crc ^ 0xFFFF

def _packet(type_byte: int, payload: bytes = b"") -> bytes:
    hdr  = struct.pack(">HBH", 0xFEEF, type_byte, len(payload))
    body = hdr + payload
    return body + struct.pack("<H", _crc16_kermit(body))

TYPE_START_VOICE = 0
TYPE_STOP_VOICE  = 1
TYPE_HEARTBEAT   = 3


# ── RTP ───────────────────────────────────────────────────────────────────────

def _rtp(payload: bytes, seq: int, ts: int, ssrc: int) -> bytes:
    return struct.pack(">BBHII", 0x80, 97, seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc) + payload


# ── ADTS frame parser ─────────────────────────────────────────────────────────

def _adts_frames(buf: bytearray):
    i = 0
    while i + 7 <= len(buf):
        if buf[i] == 0xFF and (buf[i + 1] & 0xF0) == 0xF0:
            hdr_size  = 7 if (buf[i + 1] & 0x01) else 9
            frame_len = ((buf[i + 3] & 0x03) << 11) | (buf[i + 4] << 3) | (buf[i + 5] >> 5)
            if frame_len < hdr_size or i + frame_len > len(buf):
                break
            yield bytes(buf[i : i + frame_len])
            i += frame_len
        else:
            i += 1
    del buf[:i]


# ── Main test ─────────────────────────────────────────────────────────────────

def main():
    print(f"Testing doorbell audio on {DOORBELL_IP}")

    # 1. Open control channel
    print("  Connecting to control port 54324 …", end=" ", flush=True)
    ctrl = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ctrl.settimeout(4)
    try:
        ctrl.connect((DOORBELL_IP, CTRL_PORT))
    except Exception as e:
        print(f"FAILED\n  ✗ Cannot reach {DOORBELL_IP}:54324 — {e}")
        print("  Make sure HA and the doorbell are on the same LAN.")
        return
    print("OK")

    # 2. START_VOICE
    ts_ms = int(time.time() * 1000)
    ctrl.sendall(_packet(TYPE_START_VOICE, struct.pack(">Q", ts_ms)))
    try:
        ack = ctrl.recv(16)
        print(f"  START_VOICE ACK: {ack.hex()}")
    except Exception as e:
        print(f"  ✗ No ACK from doorbell: {e}")
        ctrl.close()
        return

    # 3. UDP audio socket
    udp  = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ssrc = 0xDEADBEEF
    seq  = 0
    ts   = 0

    # 4. ffmpeg: generate 1 kHz sine → PCM16LE 16 kHz → AAC-LC ADTS
    print(f"  Sending {DURATION_SEC}s 1 kHz tone … (you should hear it through the doorbell)")
    ffmpeg = subprocess.Popen(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", f"sine=frequency=1000:duration={DURATION_SEC}",
            "-c:a", "aac", "-profile:a", "aac_low",
            "-b:a", "32k", "-ar", "16000", "-ac", "1",
            "-f", "adts", "pipe:1",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )

    # 5. Heartbeat thread
    stop_hb = threading.Event()
    def heartbeat():
        while not stop_hb.wait(5):
            try:
                ctrl.sendall(_packet(TYPE_HEARTBEAT))
            except Exception:
                break
    threading.Thread(target=heartbeat, daemon=True).start()

    # 6. Read ADTS frames, wrap in RTP, send UDP
    buf = bytearray()
    assert ffmpeg.stdout
    while True:
        chunk = ffmpeg.stdout.read(512)
        if not chunk:
            break
        buf.extend(chunk)
        for frame in _adts_frames(buf):
            pkt = _rtp(frame, seq, ts, ssrc)
            udp.sendto(pkt, (DOORBELL_IP, AUDIO_PORT))
            seq  = (seq + 1) & 0xFFFF
            ts   = (ts + 1024) & 0xFFFFFFFF

    ffmpeg.wait()

    # 7. STOP_VOICE
    stop_hb.set()
    ctrl.sendall(_packet(TYPE_STOP_VOICE))
    ctrl.close()
    udp.close()
    print("  ✓ Done — did you hear the tone?")


if __name__ == "__main__":
    main()
