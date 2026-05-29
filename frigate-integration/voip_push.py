#!/usr/bin/env python3
"""
voip_push.py — Send a VoIP PushKit notification to the Apex iOS app.

This script sends a push directly to Apple's APNs VoIP endpoint (not via Expo)
using JWT (p8 key) authentication. The Apex app must receive this push to show
the native CallKit incoming call screen, even from a killed/locked state.

Usage:
    python3 voip_push.py \\
        --token <device-voip-token-from-apex-settings> \\
        --key-id <APNs-Key-ID-from-apple-developer> \\
        --team-id <Apple-Team-ID-from-membership> \\
        --key-path /path/to/AuthKey_KEYID.p8 \\
        --camera doorbell \\
        --caller "Front Door"

All APNs config args can also be set as environment variables:
    APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_PATH, APNS_BUNDLE_ID

Requirements: Python 3.8+, PyJWT, cryptography
    pip3 install pyjwt cryptography

One-time Apple Developer setup:
    1. developer.apple.com → Certificates → Keys → "+" → enable APNs
    2. Download AuthKey_KEYID.p8, record Key ID (10 chars) and Team ID
    3. Place .p8 file on your HA instance, e.g. /config/apns/AuthKey_KEYID.p8
"""

import argparse
import http.client
import json
import os
import ssl
import sys
import time
import uuid

try:
    import jwt
except ImportError:
    print("ERROR: PyJWT not installed. Run: pip3 install pyjwt cryptography", file=sys.stderr)
    sys.exit(1)

APNS_HOST = "api.push.apple.com"
APNS_PORT = 443


def make_jwt(key_id: str, team_id: str, key_path: str) -> str:
    with open(key_path, "r") as f:
        private_key = f.read()
    payload = {"iss": team_id, "iat": int(time.time())}
    token = jwt.encode(
        payload=payload,
        key=private_key,
        algorithm="ES256",
        headers={"alg": "ES256", "kid": key_id},
    )
    return token if isinstance(token, str) else token.decode("utf-8")


def send_voip_push(
    device_token: str,
    bundle_id: str,
    jwt_token: str,
    camera: str,
    caller: str,
) -> None:
    # Payload consumed by the native AppDelegate handler + useDoorbellCall.ts.
    # "uuid" ties the CallKit call to the camera so the app knows which feed to
    # open when the call is answered.
    payload = json.dumps({
        "uuid": str(uuid.uuid4()),
        "camera": camera,
        "caller": caller,
    }).encode("utf-8")

    headers = {
        "authorization": f"bearer {jwt_token}",
        "apns-push-type": "voip",
        "apns-topic": f"{bundle_id}.voip",  # MUST end in .voip for VoIP pushes
        "apns-priority": "10",              # immediate delivery
        "apns-expiration": "0",             # deliver now or not at all
        "apns-id": str(uuid.uuid4()),
        "content-type": "application/json",
    }

    # APNs uses HTTP/2 in production; http.client falls back to HTTP/1.1 over TLS.
    # For a single doorbell push this is sufficient.
    ctx = ssl.create_default_context()
    conn = http.client.HTTPSConnection(APNS_HOST, APNS_PORT, context=ctx)

    try:
        conn.request("POST", f"/3/device/{device_token}", payload, headers)
        resp = conn.getresponse()
        body = resp.read().decode("utf-8")
        if resp.status == 200:
            print(f"✓ VoIP push sent  (APNs-Id: {headers['apns-id']})")
        else:
            print(f"✗ APNs error {resp.status}: {body}", file=sys.stderr)
            sys.exit(1)
    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Send VoIP push to Apex doorbell app")
    parser.add_argument("--token",     required=True,  help="Device VoIP push token (from Apex Settings → Doorbell)")
    parser.add_argument("--key-id",    default=os.environ.get("APNS_KEY_ID"),   required=not os.environ.get("APNS_KEY_ID"),   help="APNs Key ID (10 chars)")
    parser.add_argument("--team-id",   default=os.environ.get("APNS_TEAM_ID"),  required=not os.environ.get("APNS_TEAM_ID"),  help="Apple Team ID")
    parser.add_argument("--key-path",  default=os.environ.get("APNS_KEY_PATH"), required=not os.environ.get("APNS_KEY_PATH"), help="Path to AuthKey_KEYID.p8")
    parser.add_argument("--bundle-id", default=os.environ.get("APNS_BUNDLE_ID", "com.brandontoth.apexsight"), help="App bundle ID")
    parser.add_argument("--camera",  default="doorbell",    help="Camera/stream name in go2rtc")
    parser.add_argument("--caller",  default="Front Door",  help="Caller name shown on CallKit screen")
    args = parser.parse_args()

    jwt_token = make_jwt(args.key_id, args.team_id, args.key_path)
    send_voip_push(args.token, args.bundle_id, jwt_token, args.camera, args.caller)


if __name__ == "__main__":
    main()
