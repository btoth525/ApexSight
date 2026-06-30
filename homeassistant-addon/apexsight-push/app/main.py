"""ApexSight push relay — FastAPI app.

Public API (called by the iOS app + the Home Assistant bridge addon):
  POST /v1/register    — an iPhone registers its APNs device token + pairing code
  POST /v1/unregister  — remove a device token
  POST /v1/notify      — a household's HA bridge forwards a Frigate alert
  GET  /healthz        — liveness probe

Admin web GUI (browser, password-protected): mounted at /admin — upload the
.p8, set Key/Team/Bundle IDs, view devices, send a test push.
"""
import asyncio
import datetime
import json
import os
import time
from collections import defaultdict, deque
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from starlette.middleware.sessions import SessionMiddleware

from . import apns, config, db, recap, render, turn
from .accounts import frigate_router, router as auth_router
from .admin import router as admin_router
from .web import router as web_router

# Read from the add-on env (run.sh) — used by the daily-recap scheduler.
PAIRING_CODE = os.environ.get("PAIRING_CODE", "").upper().strip()

app = FastAPI(title="ApexSight Push Relay", docs_url=None, redoc_url=None)
# Secure cookie by default (the relay sits behind an HTTPS tunnel). Set
# APEX_SESSION_HTTPS_ONLY=0 only if you must reach it over plain HTTP.
app.add_middleware(
    SessionMiddleware,
    secret_key=config.session_secret(),
    https_only=os.environ.get("APEX_SESSION_HTTPS_ONLY", "1") != "0",
)

_static_dir = os.path.join(os.path.dirname(__file__), "static")
app.mount("/static", StaticFiles(directory=_static_dir), name="static")
app.include_router(auth_router)
app.include_router(frigate_router)
app.include_router(admin_router)
app.include_router(web_router)


@app.on_event("startup")
async def _startup() -> None:
    db.init()
    asyncio.create_task(_recap_scheduler())


# ---- daily recap scheduler --------------------------------------------------

async def _recap_scheduler() -> None:
    """Once a minute, send the household's daily recap if it's due and not yet sent
    today — so the daily summary arrives reliably even with the app fully closed."""
    while True:
        try:
            await _maybe_send_recap()
        except Exception as exc:
            print("[recap] error:", exc, flush=True)
        await asyncio.sleep(60)


async def _maybe_send_recap() -> None:
    if not PAIRING_CODE or not apns.is_configured():
        return
    raw = db.get_config(f"recap:{PAIRING_CODE}")
    if not raw:
        return
    try:
        cfg = json.loads(raw)
    except json.JSONDecodeError:
        return
    if not cfg.get("enabled"):
        return
    if not db.devices_for(PAIRING_CODE):
        return

    # The app syncs the user's UTC offset (seconds) so we evaluate "their" time
    # without needing a tz database in the container.
    tz = datetime.timezone(datetime.timedelta(seconds=int(cfg.get("tz_offset", 0))))
    now = datetime.datetime.now(tz)
    today = now.strftime("%Y-%m-%d")
    if db.get_config(f"recap_sent:{PAIRING_CODE}") == today:
        return
    target = int(cfg.get("hour", 21)) * 60 + int(cfg.get("minute", 0))
    if (now.hour * 60 + now.minute) < target:
        return

    # Build from the events the bridge accumulated off MQTT today (no Frigate query).
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    rows = db.recap_events_between(PAIRING_CODE, midnight.timestamp(), now.timestamp())
    title, body = recap.format_recap(rows)
    payload = apns.build_payload(title=title, body=body, apex_url="apex://recap")
    await apns.deliver_to_pairing(PAIRING_CODE, payload, collapse_id=f"recap-{today}")
    db.set_config(f"recap_sent:{PAIRING_CODE}", today)
    db.prune_recap_events(midnight.timestamp() - 2 * 86_400)   # keep ~2 days of history
    print(f"[recap] sent daily recap to {PAIRING_CODE} for {today} ({len(rows)} events)", flush=True)


# ---- naive per-IP rate limiting --------------------------------------------

_hits: dict[str, deque] = defaultdict(deque)


def rate_limit(request: Request) -> None:
    ip = request.client.host if request.client else "unknown"
    now = time.time()
    window = _hits[ip]
    while window and now - window[0] > 60:
        window.popleft()
    if len(window) >= config.RATE_LIMIT_PER_MINUTE:
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    window.append(now)


# ---- request models ---------------------------------------------------------

class RegisterIn(BaseModel):
    device_token: str = Field(min_length=32)
    pairing_code: str = Field(min_length=4, max_length=64)
    environment: str = "production"      # "production" | "sandbox"
    platform: str = "ios"


class UnregisterIn(BaseModel):
    device_token: str


class TestIn(BaseModel):
    device_token: str
    environment: str = "production"


class NotifyIn(BaseModel):
    pairing_code: str
    title: str
    body: str = ""
    camera: str = ""
    review_id: str = ""
    apex_url: str = ""
    snapshot_url: str = ""
    thumbnail_url: str = ""
    snapshot_path: str = ""
    frigate_token: str = ""
    collapse_id: str = ""
    silent: bool = False
    # Raw event fields — when present the relay renders title/body/media itself
    # using the household's saved style (set via /v1/style), so the in-app GUI
    # controls even app-closed notifications.
    camera_name: str = ""
    labels: list[str] = []
    sub_labels: list[str] = []
    zones: list[str] = []
    score: Optional[float] = None
    severity: str = ""
    detection_id: str = ""
    frigate_base_url: str = ""
    recognized_license_plate: str = ""
    stage: str = ""
    start_time: Optional[float] = None    # epoch seconds — drives the Live Activity timer


class StyleIn(BaseModel):
    pairing_code: str
    style: dict


class GateIn(BaseModel):
    pairing_code: str
    disarmed: bool = False
    snoozed_until: float = 0.0   # epoch seconds; 0 = not snoozed


class RecapIn(BaseModel):
    pairing_code: str
    enabled: bool = False
    hour: int = 21
    minute: int = 0
    tz_offset: int = 0           # seconds from GMT, so the relay sends at the user's local time


class ActivityRegisterIn(BaseModel):
    pairing_code: str = Field(min_length=4, max_length=64)
    token: str = Field(min_length=32)
    environment: str = "production"
    kind: str = "start"          # "start" = Live Activity push-to-start token


# ---- public API -------------------------------------------------------------

@app.get("/healthz")
def healthz() -> dict:
    return {
        "ok": True,
        "apns_configured": apns.is_configured(),
        "devices": db.device_count(),
        "turn_configured": turn.is_configured(),
    }


class TurnIn(BaseModel):
    pairing_code: str = Field(min_length=4, max_length=64)


@app.post("/v1/turn-credentials")
async def turn_credentials(body: TurnIn, _: None = Depends(rate_limit)) -> list[dict]:
    """Mint short-lived Cloudflare TURN ICE servers for a paired household so two-way talk
    works away from home. Auth = the pairing code (same as every other /v1/* call)."""
    code = body.pairing_code.upper().strip()
    if not db.devices_for(code):
        raise HTTPException(status_code=403, detail="unknown pairing code")
    try:
        return await turn.mint_ice_servers()      # [{urls, username?, credential?}]
    except turn.TurnNotConfigured:
        raise HTTPException(status_code=503, detail="TURN not configured on relay")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"TURN mint failed: {exc}")


@app.post("/v1/register")
def register(body: RegisterIn, _: None = Depends(rate_limit)) -> dict:
    env = body.environment if body.environment in ("production", "sandbox") else "production"
    db.upsert_device(body.device_token, body.pairing_code.upper().strip(), env, body.platform)
    return {"ok": True, "pairing_code": body.pairing_code.upper().strip()}


@app.post("/v1/unregister")
def unregister(body: UnregisterIn, _: None = Depends(rate_limit)) -> dict:
    db.delete_device(body.device_token)
    return {"ok": True}


@app.post("/v1/test")
async def test_push(body: TestIn, _: None = Depends(rate_limit)) -> dict:
    """Send a test push to one device token — powers the in-app Test button."""
    if not apns.is_configured():
        raise HTTPException(status_code=503, detail="APNs not configured on relay")
    env = body.environment if body.environment in ("production", "sandbox") else "production"
    payload = apns.build_payload(
        title="\U0001f6a8 ApexSight test alert",
        body="Instant push is working — you'll get alerts with the app closed.",
        camera="relay_test",
        review_id="relay-test",
        apex_url="apex://review?id=relay-test",
    )
    ok, detail = await apns.send_to_token(body.device_token, env, payload)
    if not ok:
        raise HTTPException(status_code=502, detail=detail)
    return {"ok": True}


@app.post("/v1/notify")
async def notify(body: NotifyIn, _: None = Depends(rate_limit)) -> dict:
    if not apns.is_configured():
        raise HTTPException(status_code=503, detail="APNs not configured on relay")
    code = body.pairing_code.upper().strip()
    if not db.devices_for(code):
        # Nothing registered under this code yet — not an error the bridge should retry on.
        return {"ok": True, "devices": 0, "sent": 0, "note": "no devices for pairing code"}

    # Household gate — keeps app-closed pushes consistent with the in-app delivery gate.
    # When the user has Disarmed or Snoozed (from the app, a widget, Siri or CarPlay,
    # synced via /v1/gate), suppress delivery instead of buzzing them anyway.
    gate_raw = db.get_config(f"gate:{code}")
    if gate_raw:
        try:
            gate = json.loads(gate_raw)
        except json.JSONDecodeError:
            gate = {}
        if gate.get("disarmed"):
            return {"ok": True, "sent": 0, "note": "disarmed"}
        snoozed_until = gate.get("snoozed_until") or 0
        if snoozed_until and time.time() < float(snoozed_until):
            return {"ok": True, "sent": 0, "note": "snoozed"}

    title, text = body.title, body.body
    snapshot_url, thumbnail_url = body.snapshot_url, body.thumbnail_url

    # Raw event present → render here using the household's saved style (or defaults),
    # so the app's GUI controls the content even when the app is closed.
    if body.detection_id or body.labels or body.sub_labels:
        raw = db.get_config(f"style:{code}")
        style = {}
        if raw:
            try:
                style = json.loads(raw)
            except json.JSONDecodeError:
                style = {}
        rendered = render.render(
            {
                "camera": body.camera,
                "camera_name": body.camera_name,
                "labels": body.labels,
                "sub_labels": body.sub_labels,
                "zones": body.zones,
                "score": body.score,
                "severity": body.severity,
                "detection_id": body.detection_id,
                "frigate_base_url": body.frigate_base_url,
                "recognized_license_plate": body.recognized_license_plate,
            },
            style,
            body.stage or "alert",
        )
        title = rendered["title"] or title
        text = rendered["body"] or text
        snapshot_url = rendered["snapshot_url"] or snapshot_url
        thumbnail_url = rendered["thumbnail_url"] or thumbnail_url

    content_state = {"title": title, "detail": text, "severity": body.severity or "alert"}

    # A pure mid-incident change: just live-update the banner, no notification at all.
    if body.stage == "update":
        try:
            await apns.update_live_activity_for_pairing(code, content_state)
        except Exception as exc:
            print("[liveactivity] update failed:", exc, flush=True)
        return {"ok": True, "stage": "update"}

    payload = apns.build_payload(
        title=title,
        body=text,
        camera=body.camera,
        review_id=body.review_id,
        apex_url=body.apex_url,
        snapshot_url=snapshot_url,
        thumbnail_url=thumbnail_url,
        snapshot_path=body.snapshot_path,
        frigate_token=body.frigate_token,
        silent=body.silent,
    )
    result = await apns.deliver_to_pairing(code, payload, collapse_id=body.collapse_id)

    # Drive the incident Live Activity. Wrapped so a hiccup never affects alert delivery:
    #   • fresh alert → push-start it (appears even with the app closed),
    #   • review ended → end it (clears the Lock Screen banner).
    try:
        if body.stage == "final":
            await apns.update_live_activity_for_pairing(code, content_state, end=True)
        elif body.stage in ("", "alert") and body.severity in ("alert", ""):
            started_at = body.start_time or time.time()
            await apns.start_live_activity_for_pairing(
                code,
                content_state=content_state,
                attributes={"camera": body.camera, "startedAt": float(started_at)},
            )
    except Exception as exc:
        print("[liveactivity] error:", exc, flush=True)

    return {"ok": result["sent"] > 0 or result["devices"] == 0, **result}


@app.post("/v1/style")
def set_style(body: StyleIn, _: None = Depends(rate_limit)) -> dict:
    """The iOS app saves its notification style here, keyed by pairing code, so the
    relay can render app-closed pushes the way the user configured in the GUI."""
    code = body.pairing_code.upper().strip()
    db.set_config(f"style:{code}", json.dumps(body.style))
    return {"ok": True}


@app.post("/v1/gate")
def set_gate(body: GateIn, _: None = Depends(rate_limit)) -> dict:
    """The iOS app mirrors its Disarm / Snooze state here so app-closed pushes are
    suppressed while disarmed or snoozed, matching the in-app delivery gate."""
    code = body.pairing_code.upper().strip()
    db.set_config(
        f"gate:{code}",
        json.dumps({"disarmed": bool(body.disarmed), "snoozed_until": float(body.snoozed_until or 0)}),
    )
    return {"ok": True}


@app.post("/v1/activity/register")
def register_activity(body: ActivityRegisterIn, _: None = Depends(rate_limit)) -> dict:
    """An iPhone registers its Live Activity push-to-start token so the relay can start an
    incident banner on the Lock Screen even when the app is fully closed."""
    env = body.environment if body.environment in ("production", "sandbox") else "production"
    kind = body.kind if body.kind in ("start", "update") else "start"
    db.upsert_activity_token(body.token, body.pairing_code.upper().strip(), kind, env)
    db.prune_activity_tokens(time.time() - 30 * 86_400)   # drop tokens not refreshed in ~30d
    return {"ok": True}


@app.post("/v1/recap")
def set_recap(body: RecapIn, _: None = Depends(rate_limit)) -> dict:
    """The iOS app saves its Daily Recap schedule here so the relay can send the
    summary at the chosen local time even when the app is fully closed."""
    code = body.pairing_code.upper().strip()
    db.set_config(
        f"recap:{code}",
        json.dumps({
            "enabled": bool(body.enabled),
            "hour": int(body.hour),
            "minute": int(body.minute),
            "tz_offset": int(body.tz_offset),
        }),
    )
    return {"ok": True}
