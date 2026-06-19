"""Account system for ApexSight.

An account = an identity (email+password or Sign in with Apple) plus a unique,
secret `ingest_token`. The token replaces the old shared pairing code: the iOS app
uses it everywhere it used the pairing code, and the user's Home Assistant bridge
forwards Frigate events with it — so each account is fully isolated and nobody can
receive anyone else's alerts.

No new dependencies: password hashing is stdlib PBKDF2, session tokens are PyJWT
(already used for APNs), and Sign in with Apple is verified against Apple's JWKS.
"""
import hashlib
import hmac
import json
import secrets
import time
from collections import defaultdict, deque

import httpx
import jwt
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from jwt.algorithms import RSAAlgorithm
from pydantic import BaseModel, Field

from . import config, db

router = APIRouter(prefix="/v1/auth")

_ALG = "HS256"
_SESSION_DAYS = 365
_APPLE_ISSUER = "https://appleid.apple.com"
_APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"


# ---- password hashing (stdlib PBKDF2) ---------------------------------------

def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    iters = 200_000
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iters)
    return f"pbkdf2_sha256${iters}${salt.hex()}${dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iters, salt_hex, hash_hex = stored.split("$")
        if algo != "pbkdf2_sha256":
            return False
        dk = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt_hex), int(iters))
        return hmac.compare_digest(dk.hex(), hash_hex)
    except Exception:
        return False


# ---- session tokens (PyJWT, HS256 with the relay's secret) -------------------

def make_session_token(account_id: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {"sub": account_id, "iat": now, "exp": now + _SESSION_DAYS * 86_400},
        config.session_secret(),
        algorithm=_ALG,
    )


def verify_session_token(token: str) -> str | None:
    try:
        payload = jwt.decode(token, config.session_secret(), algorithms=[_ALG])
        return payload.get("sub")
    except Exception:
        return None


# ---- Sign in with Apple ------------------------------------------------------

_apple_keys: dict = {}
_apple_keys_at: float = 0.0


async def _apple_signing_keys() -> dict:
    global _apple_keys, _apple_keys_at
    if _apple_keys and (time.time() - _apple_keys_at) < 3600:
        return _apple_keys
    async with httpx.AsyncClient(timeout=10.0) as client:
        data = (await client.get(_APPLE_KEYS_URL)).json()
    keys = {jwk["kid"]: RSAAlgorithm.from_jwk(json.dumps(jwk)) for jwk in data.get("keys", [])}
    _apple_keys, _apple_keys_at = keys, time.time()
    return keys


async def verify_apple_identity_token(identity_token: str) -> tuple[str, str | None]:
    """Returns (apple_sub, email). Raises on any verification failure."""
    kid = jwt.get_unverified_header(identity_token).get("kid", "")
    key = (await _apple_signing_keys()).get(kid)
    if key is None:
        raise ValueError("unknown Apple signing key")
    payload = jwt.decode(
        identity_token,
        key=key,
        algorithms=["RS256"],
        audience=config.DEFAULT_BUNDLE_ID,
        issuer=_APPLE_ISSUER,
    )
    return payload["sub"], payload.get("email")


# ---- brute-force limiter for auth endpoints ---------------------------------

_auth_hits: dict[str, deque] = defaultdict(deque)


def _client_ip(request: Request) -> str:
    cf = request.headers.get("cf-connecting-ip")
    if cf:
        return cf.strip()
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def auth_rate_limit(request: Request) -> None:
    ip = _client_ip(request)
    now = time.time()
    window = _auth_hits[ip]
    while window and now - window[0] > 300:
        window.popleft()
    if len(window) >= 20:        # 20 auth attempts / 5 min / IP
        raise HTTPException(status_code=429, detail="Too many attempts. Try again in a few minutes.")
    window.append(now)


# ---- helpers ----------------------------------------------------------------

def _new_account_id() -> str:
    return secrets.token_hex(16)


def _new_ingest_token() -> str:
    return "apex_" + secrets.token_urlsafe(24)


def _session(row) -> dict:
    return {"token": make_session_token(row["id"]), "ingest_token": row["ingest_token"], "email": row["email"]}


def require_account(authorization: str = Header(default="")):
    token = authorization[7:].strip() if authorization.lower().startswith("bearer ") else authorization.strip()
    account_id = verify_session_token(token)
    if not account_id:
        raise HTTPException(status_code=401, detail="Sign in required.")
    row = db.account_by_id(account_id)
    if row is None:
        raise HTTPException(status_code=401, detail="Account not found.")
    return row


# ---- request models ---------------------------------------------------------

class SignupIn(BaseModel):
    email: str = Field(min_length=3, max_length=200)
    password: str = Field(min_length=8, max_length=200)


class LoginIn(BaseModel):
    email: str = Field(min_length=3, max_length=200)
    password: str = Field(min_length=1, max_length=200)


class AppleIn(BaseModel):
    identity_token: str = Field(min_length=16)
    email: str | None = None


# ---- endpoints --------------------------------------------------------------

@router.post("/signup")
def signup(body: SignupIn, _: None = Depends(auth_rate_limit)) -> dict:
    email = body.email.strip().lower()
    if "@" not in email or "." not in email:
        raise HTTPException(status_code=400, detail="Enter a valid email address.")
    if db.account_by_email(email):
        raise HTTPException(status_code=409, detail="An account with that email already exists.")
    account_id = _new_account_id()
    db.create_account(account_id, _new_ingest_token(), email=email, password_hash=hash_password(body.password))
    return _session(db.account_by_id(account_id))


@router.post("/login")
def login(body: LoginIn, _: None = Depends(auth_rate_limit)) -> dict:
    email = body.email.strip().lower()
    row = db.account_by_email(email)
    if not row or not row["password_hash"] or not verify_password(body.password, row["password_hash"]):
        raise HTTPException(status_code=401, detail="Wrong email or password.")
    return _session(row)


@router.post("/apple")
async def apple(body: AppleIn, _: None = Depends(auth_rate_limit)) -> dict:
    try:
        apple_sub, apple_email = await verify_apple_identity_token(body.identity_token)
    except Exception:
        raise HTTPException(status_code=401, detail="Apple sign-in could not be verified.")
    row = db.account_by_apple_sub(apple_sub)
    if row is None:
        account_id = _new_account_id()
        email = (body.email or apple_email or "").strip().lower() or None
        db.create_account(account_id, _new_ingest_token(), email=email, apple_sub=apple_sub)
        row = db.account_by_id(account_id)
    return _session(row)


@router.get("/me")
def me(account=Depends(require_account)) -> dict:
    return {"email": account["email"], "ingest_token": account["ingest_token"]}


@router.post("/rotate")
def rotate(account=Depends(require_account)) -> dict:
    """Issue a fresh ingest token (e.g. if the old one leaked). The user must update
    their Home Assistant bridge config to match."""
    db.set_ingest_token(account["id"], _new_ingest_token())
    return {"ingest_token": db.account_by_id(account["id"])["ingest_token"]}


@router.delete("/me")
def delete_me(account=Depends(require_account)) -> dict:
    db.delete_account(account["id"])
    return {"ok": True}
