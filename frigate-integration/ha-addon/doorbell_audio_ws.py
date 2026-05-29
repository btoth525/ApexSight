#!/usr/bin/env python3
"""
Aqara G410 two-way audio WebSocket proxy.

Phone mic → WebSocket (PCM16LE 16 kHz mono)
  → ffmpeg (PCM → AAC-LC ADTS)
  → UDP RTP → doorbell:54323

Control channel: TCP doorbell:54324
  START_VOICE on connect, HEARTBEAT every 5 s, STOP_VOICE on disconnect.

Usage:
  pip3 install websockets
  DOORBELL_IP=192.168.1.67 FRIGATE_TOKEN=<jwt> python3 doorbell_audio_ws.py

Environment variables:
  DOORBELL_IP      LAN IP of the Aqara doorbell  (default: 192.168.1.67)
  WS_PORT          Port this server listens on   (default: 8556)
  FRIGATE_TOKEN    Frigate JWT – connections must supply ?token=<this>
                   Leave empty to disable auth (LAN-only deployments).
"""

import asyncio
import os
import random
import socket
import struct
import time
import logging
from typing import Optional

import websockets
from websockets.server import WebSocketServerProtocol

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DOORBELL_IP   = os.environ.get("DOORBELL_IP",    "192.168.1.67")
CONTROL_PORT  = 54324
AUDIO_PORT    = 54323
WS_PORT       = int(os.environ.get("WS_PORT",    "8556"))
AUTH_TOKEN    = os.environ.get("FRIGATE_TOKEN",  "")

# ── Aqara control protocol ────────────────────────────────────────────────────
# Packet: Magic(2) | Type(1) | PayloadLen(2) | Payload(N) | CRC16(2)
# Magic = 0xFEEF, CRC = CRC-16/KERMIT over all preceding bytes

TYPE_START_VOICE = 0
TYPE_STOP_VOICE  = 1
TYPE_ACK         = 2
TYPE_HEARTBEAT   = 3


def _crc16_kermit(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if (crc & 1) else crc >> 1
    return crc ^ 0xFFFF


def _make_packet(type_byte: int, payload: bytes = b"") -> bytes:
    hdr  = struct.pack(">HBH", 0xFEEF, type_byte, len(payload))
    body = hdr + payload
    return body + struct.pack("<H", _crc16_kermit(body))


# ── RTP helpers ───────────────────────────────────────────────────────────────
# V=2 P=0 X=0 CC=0 | M=0 PT=97 (dynamic AAC)

def _make_rtp(payload: bytes, seq: int, ts: int, ssrc: int) -> bytes:
    hdr = struct.pack(">BBHII", 0x80, 97, seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc)
    return hdr + payload


# ── ADTS frame extractor ──────────────────────────────────────────────────────
# ADTS sync = 0xFFF (12 bits). Frame length encoded in header bits 30-42.

def _extract_adts_frames(buf: bytearray) -> list[bytes]:
    frames: list[bytes] = []
    i = 0
    while i + 7 <= len(buf):
        if buf[i] == 0xFF and (buf[i + 1] & 0xF0) == 0xF0:
            protection_absent = buf[i + 1] & 0x01
            hdr_size = 7 if protection_absent else 9
            if i + hdr_size > len(buf):
                break
            frame_len = ((buf[i + 3] & 0x03) << 11) | (buf[i + 4] << 3) | (buf[i + 5] >> 5)
            if frame_len < hdr_size or i + frame_len > len(buf):
                break
            frames.append(bytes(buf[i : i + frame_len]))
            i += frame_len
        else:
            i += 1
    del buf[:i]
    return frames


# ── Session ───────────────────────────────────────────────────────────────────

class DoorbellAudioSession:
    def __init__(self) -> None:
        self._ctrl_reader: Optional[asyncio.StreamReader] = None
        self._ctrl_writer: Optional[asyncio.StreamWriter] = None
        self._udp: Optional[socket.socket] = None
        self._ffmpeg: Optional[asyncio.subprocess.Process] = None
        self._ssrc    = random.randint(0, 0xFFFFFFFF)
        self._seq     = 0
        self._ts      = 0
        self._adts    = bytearray()
        self._hb_task: Optional[asyncio.Task] = None
        self._rd_task: Optional[asyncio.Task] = None

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    async def start(self) -> None:
        log.info("Connecting to doorbell %s:%d (control)", DOORBELL_IP, CONTROL_PORT)
        self._ctrl_reader, self._ctrl_writer = await asyncio.wait_for(
            asyncio.open_connection(DOORBELL_IP, CONTROL_PORT), timeout=3.0
        )

        ts_ms   = int(time.time() * 1000)
        payload = struct.pack(">Q", ts_ms)
        self._ctrl_writer.write(_make_packet(TYPE_START_VOICE, payload))
        await self._ctrl_writer.drain()

        ack = await asyncio.wait_for(self._ctrl_reader.read(16), timeout=3.0)
        log.info("START_VOICE ACK: %s", ack.hex())

        self._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

        self._ffmpeg = await asyncio.create_subprocess_exec(
            "ffmpeg",
            "-hide_banner", "-loglevel", "error",
            "-f", "s16le", "-ar", "16000", "-ac", "1", "-i", "pipe:0",
            "-c:a", "aac", "-profile:a", "aac_low",
            "-b:a", "32k", "-ar", "16000", "-ac", "1",
            "-f", "adts", "pipe:1",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )

        self._hb_task = asyncio.create_task(self._heartbeat())
        self._rd_task = asyncio.create_task(self._read_ffmpeg())
        log.info("DoorbellAudioSession started (SSRC=%08x)", self._ssrc)

    async def stop(self) -> None:
        log.info("Stopping DoorbellAudioSession")
        for task in (self._hb_task, self._rd_task):
            if task:
                task.cancel()

        if self._ffmpeg:
            try:
                self._ffmpeg.stdin.close()          # type: ignore[union-attr]
                await asyncio.wait_for(self._ffmpeg.wait(), timeout=2.0)
            except Exception:
                self._ffmpeg.kill()

        if self._ctrl_writer:
            try:
                self._ctrl_writer.write(_make_packet(TYPE_STOP_VOICE))
                await self._ctrl_writer.drain()
                self._ctrl_writer.close()
                await self._ctrl_writer.wait_closed()
            except Exception:
                pass

        if self._udp:
            self._udp.close()

    # ── Feed audio ─────────────────────────────────────────────────────────────

    def feed_pcm(self, data: bytes) -> None:
        """Receive raw PCM-16LE 16 kHz mono bytes from the WebSocket."""
        if self._ffmpeg and self._ffmpeg.stdin and not self._ffmpeg.stdin.is_closing():
            try:
                self._ffmpeg.stdin.write(data)
            except Exception:
                pass

    # ── Background tasks ───────────────────────────────────────────────────────

    async def _heartbeat(self) -> None:
        failures = 0
        while True:
            await asyncio.sleep(5)
            try:
                if self._ctrl_writer:
                    self._ctrl_writer.write(_make_packet(TYPE_HEARTBEAT))
                    await self._ctrl_writer.drain()
                    failures = 0
            except Exception:
                failures += 1
                if failures >= 3:
                    log.warning("Heartbeat failed 3×, giving up")
                    break

    async def _read_ffmpeg(self) -> None:
        assert self._ffmpeg and self._ffmpeg.stdout
        while True:
            chunk = await self._ffmpeg.stdout.read(4096)
            if not chunk:
                break
            self._adts.extend(chunk)
            for frame in _extract_adts_frames(self._adts):
                rtp = _make_rtp(frame, self._seq, self._ts, self._ssrc)
                assert self._udp
                self._udp.sendto(rtp, (DOORBELL_IP, AUDIO_PORT))
                self._seq  = (self._seq + 1) & 0xFFFF
                self._ts   = (self._ts + 1024) & 0xFFFFFFFF


# ── WebSocket handler ─────────────────────────────────────────────────────────

async def _handle(ws: WebSocketServerProtocol) -> None:
    # Auth: ?token=<FRIGATE_TOKEN>
    path = ws.request.path  # type: ignore[attr-defined]
    if AUTH_TOKEN:
        token = ""
        if "token=" in path:
            token = path.split("token=", 1)[1].split("&", 1)[0]
        if token != AUTH_TOKEN:
            await ws.close(4003, "Unauthorized")
            log.warning("Rejected connection from %s — bad token", ws.remote_address)
            return

    log.info("Talkback connection from %s", ws.remote_address)
    session = DoorbellAudioSession()
    try:
        await session.start()
        async for msg in ws:
            if isinstance(msg, bytes):
                session.feed_pcm(msg)
    except Exception as exc:
        log.error("Session error: %s", exc)
    finally:
        await session.stop()
        log.info("Talkback connection closed")


# ── Entry point ───────────────────────────────────────────────────────────────

async def _main() -> None:
    log.info(
        "Doorbell audio proxy  ws://0.0.0.0:%d  →  %s udp:%d tcp:%d",
        WS_PORT, DOORBELL_IP, AUDIO_PORT, CONTROL_PORT,
    )
    async with websockets.serve(_handle, "0.0.0.0", WS_PORT):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(_main())
