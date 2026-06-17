"""Daily recap builder for the relay.

Queries Frigate's /api/events for the local day and formats a one-line summary,
mirroring the in-app DailyRecap so app-closed daily notifications match what the
app would have shown. Returns None on any fetch error so the scheduler can retry.
"""
import datetime
from typing import Optional

import httpx

CARRIERS = {
    "amazon", "ups", "usps", "fedex", "dhl", "an_post", "purolator",
    "dpd", "gls", "postnl", "postnord", "canada_post", "royal_mail",
}


def _titleize(s: str) -> str:
    return s.replace("_", " ").title() if s else s


def _sub_label(event: dict) -> Optional[str]:
    sub = event.get("sub_label")
    if isinstance(sub, list):
        return sub[0] if sub else None
    return sub


async def build_recap(frigate_url: str, tz: datetime.tzinfo) -> Optional[tuple[str, str]]:
    """(title, body) for today's recap, or None if Frigate couldn't be reached."""
    now = datetime.datetime.now(tz)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    after = int(midnight.timestamp())
    before = int(now.timestamp())
    url = f"{frigate_url.rstrip('/')}/api/events?after={after}&before={before}&limit=500"
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.get(url)
        if resp.status_code != 200:
            return None
        events = resp.json()
    except Exception:
        return None

    if not isinstance(events, list):
        return None
    if not events:
        return ("📊 Daily Recap", "All quiet today — no camera activity.")

    cameras: dict[str, int] = {}
    people: set[str] = set()
    carriers: dict[str, int] = {}
    packages = 0
    for event in events:
        cam = event.get("camera", "")
        if cam:
            cameras[cam] = cameras.get(cam, 0) + 1
        label = (event.get("label") or "").lower()
        sub = _sub_label(event)
        if label == "person" and sub:
            people.add(sub)
        if label == "package":
            packages += 1
        if sub and sub.lower() in CARRIERS:
            carriers[sub.lower()] = carriers.get(sub.lower(), 0) + 1

    total = len(events)
    title = f"📊 Daily Recap — {total} event{'' if total == 1 else 's'}"

    bits: list[str] = []
    if people:
        bits.append("Seen: " + ", ".join(_titleize(p) for p in sorted(people)[:3]))
    if cameras:
        top = max(cameras.items(), key=lambda kv: kv[1])
        bits.append(f"Busiest: {_titleize(top[0])} ({top[1]})")
    if carriers:
        bits.append(", ".join(f"{_titleize(name)} 📦" for name, _ in
                              sorted(carriers.items(), key=lambda kv: -kv[1])[:3]))
    elif packages:
        bits.append(f"{packages} 📦")
    body = " · ".join(bits) if bits else f"{total} events across {len(cameras)} cameras."
    return (title, body)
