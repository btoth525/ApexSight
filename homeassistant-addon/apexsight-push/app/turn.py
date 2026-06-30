"""Cloudflare Realtime TURN credential minting for remote two-way talk.

Keeps the long-lived TURN key server-side (uploaded via the admin GUI, like the .p8)
and mints short-lived ICE credentials on demand. No secrets live here."""
import httpx

from . import db

_CF = "https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/generate-ice-servers"


class TurnNotConfigured(Exception):
    pass


def is_configured() -> bool:
    return bool(db.get_config("turn_key_id") and db.get_config("turn_key_token"))


async def mint_ice_servers(ttl: int = 86_400) -> list[dict]:
    key_id = db.get_config("turn_key_id")
    token = db.get_config("turn_key_token")
    if not (key_id and token):
        raise TurnNotConfigured("TURN key not set. Add it in admin settings.")
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(
            _CF.format(key_id=key_id),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            json={"ttl": ttl},
        )
    resp.raise_for_status()
    cleaned: list[dict] = []
    for s in resp.json().get("iceServers", []):
        urls = s.get("urls", [])
        if isinstance(urls, str):
            urls = [urls]
        urls = [u for u in urls if ":53" not in u]   # NON-trickle: strip :53 (they time out)
        if not urls:
            continue
        entry = {"urls": urls}
        if s.get("username"):
            entry["username"] = s["username"]
        if s.get("credential"):
            entry["credential"] = s["credential"]
        cleaned.append(entry)
    return cleaned
