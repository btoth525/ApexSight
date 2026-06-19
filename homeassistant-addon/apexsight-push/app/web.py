"""Public account website: sign up, log in, and a dashboard where a user gets the
ingest token + Home Assistant bridge config to link their own Frigate. Session-cookie
auth (separate from the relay-owner /admin area)."""
import os

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from . import accounts, config, db, mailer

router = APIRouter()
_templates = Jinja2Templates(directory=os.path.join(os.path.dirname(__file__), "templates"))


def _current_account(request: Request):
    account_id = request.session.get("account_id")
    return db.account_by_id(account_id) if account_id else None


def _relay_base(request: Request) -> str:
    # The public origin the user points their bridge at (honours the tunnel/proxy).
    proto = request.headers.get("x-forwarded-proto", request.url.scheme)
    host = request.headers.get("x-forwarded-host") or request.headers.get("host") or request.url.netloc
    return f"{proto}://{host}".rstrip("/")


@router.get("/", response_class=HTMLResponse)
def landing(request: Request):
    if _current_account(request):
        return RedirectResponse("/dashboard", status_code=303)
    return _templates.TemplateResponse("site/landing.html", {"request": request})


@router.get("/signup", response_class=HTMLResponse)
def signup_page(request: Request):
    return _templates.TemplateResponse("site/signup.html", {"request": request, "error": None})


@router.post("/signup")
def signup_submit(request: Request, email: str = Form(...), password: str = Form(...)):
    email = email.strip().lower()
    if "@" not in email or "." not in email or len(password) < 8:
        return _templates.TemplateResponse(
            "site/signup.html",
            {"request": request, "error": "Enter a valid email and a password of at least 8 characters."},
            status_code=400,
        )
    if db.account_by_email(email):
        return _templates.TemplateResponse(
            "site/signup.html",
            {"request": request, "error": "An account with that email already exists."},
            status_code=409,
        )
    account_id = accounts._new_account_id()
    db.create_account(account_id, accounts._new_ingest_token(), email=email,
                      password_hash=accounts.hash_password(password))
    request.session["account_id"] = account_id
    _send_verification(request, account_id, email)
    return RedirectResponse("/dashboard", status_code=303)


def _send_verification(request: Request, account_id: str, email: str) -> None:
    if not (config.smtp_configured() and email):
        return
    base = config.PUBLIC_URL or _relay_base(request)
    token = accounts.make_action_token(account_id, "verify", 24 * 3600)
    mailer.send_verification(email, f"{base}/verify?token={token}")


@router.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    return _templates.TemplateResponse("site/login.html", {"request": request, "error": None})


@router.post("/login")
def login_submit(request: Request, email: str = Form(...), password: str = Form(...)):
    row = db.account_by_email(email.strip().lower())
    if not row or not row["password_hash"] or not accounts.verify_password(password, row["password_hash"]):
        return _templates.TemplateResponse(
            "site/login.html",
            {"request": request, "error": "Wrong email or password."},
            status_code=401,
        )
    request.session["account_id"] = row["id"]
    return RedirectResponse("/dashboard", status_code=303)


@router.get("/dashboard", response_class=HTMLResponse)
def dashboard(request: Request):
    account = _current_account(request)
    if not account:
        return RedirectResponse("/login", status_code=303)
    token = account["ingest_token"]
    return _templates.TemplateResponse(
        "site/dashboard.html",
        {
            "request": request,
            "email": account["email"],
            "ingest_token": token,
            "relay_base": _relay_base(request),
            "device_count": len(db.devices_for(token)),
            "frigate_url": account["frigate_url"] or "",
            "frigate_username": account["frigate_username"] or "",
            "frigate_connected": bool(account["frigate_url"]),
            "email_verified": bool(account["email_verified"]),
            "needs_verify": bool(account["email"]) and not account["email_verified"] and config.smtp_configured(),
        },
    )


# ---- email verification + password reset ------------------------------------

@router.post("/resend-verification")
def resend_verification(request: Request):
    account = _current_account(request)
    if account and not account["email_verified"]:
        _send_verification(request, account["id"], account["email"])
    return RedirectResponse("/dashboard", status_code=303)


@router.get("/verify", response_class=HTMLResponse)
def verify_email(request: Request, token: str = ""):
    account_id = accounts.verify_action_token(token, "verify")
    if account_id:
        db.set_email_verified(account_id)
    return _templates.TemplateResponse("site/message.html", {
        "request": request,
        "title": "Email verified" if account_id else "Link expired",
        "message": "You're all set — your email is verified." if account_id
                   else "This verification link is invalid or has expired. Sign in and resend it from your dashboard.",
        "ok": bool(account_id),
    })


@router.get("/forgot", response_class=HTMLResponse)
def forgot_page(request: Request):
    return _templates.TemplateResponse("site/forgot.html",
                                       {"request": request, "sent": False, "smtp": config.smtp_configured()})


@router.post("/forgot")
def forgot_submit(request: Request, email: str = Form(...)):
    addr = email.strip().lower()
    row = db.account_by_email(addr)
    if row and config.smtp_configured():
        base = config.PUBLIC_URL or _relay_base(request)
        token = accounts.make_action_token(row["id"], "reset", 3600)
        mailer.send_password_reset(addr, f"{base}/reset?token={token}")
    # Always report success — never reveal whether an email is registered.
    return _templates.TemplateResponse("site/forgot.html",
                                       {"request": request, "sent": True, "smtp": config.smtp_configured()})


@router.get("/reset", response_class=HTMLResponse)
def reset_page(request: Request, token: str = ""):
    valid = accounts.verify_action_token(token, "reset") is not None
    return _templates.TemplateResponse("site/reset.html",
                                       {"request": request, "token": token, "valid": valid, "error": None})


@router.post("/reset")
def reset_submit(request: Request, token: str = Form(...), password: str = Form(...)):
    account_id = accounts.verify_action_token(token, "reset")
    if not account_id:
        return _templates.TemplateResponse("site/reset.html",
            {"request": request, "token": token, "valid": False,
             "error": "This reset link is invalid or has expired."}, status_code=400)
    if len(password) < 8:
        return _templates.TemplateResponse("site/reset.html",
            {"request": request, "token": token, "valid": True,
             "error": "Password must be at least 8 characters."}, status_code=400)
    db.set_password_hash(account_id, accounts.hash_password(password))
    db.set_email_verified(account_id)   # resetting via the emailed link also proves ownership
    request.session["account_id"] = account_id
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/frigate")
def save_frigate(request: Request, url: str = Form(...), username: str = Form(""), password: str = Form("")):
    account = _current_account(request)
    if not account:
        return RedirectResponse("/login", status_code=303)
    secret = accounts.encrypt_secret(password) if password else None
    db.set_frigate_profile(account["id"], url.strip(), username.strip(), secret)
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/rotate")
def rotate(request: Request):
    account = _current_account(request)
    if not account:
        return RedirectResponse("/login", status_code=303)
    db.set_ingest_token(account["id"], accounts._new_ingest_token())
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/logout")
def logout(request: Request):
    request.session.pop("account_id", None)
    return RedirectResponse("/", status_code=303)


@router.post("/delete")
def delete(request: Request):
    account = _current_account(request)
    if account:
        db.delete_account(account["id"])
        request.session.pop("account_id", None)
    return RedirectResponse("/", status_code=303)
