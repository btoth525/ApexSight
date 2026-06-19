"""Public account website: sign up, log in, and a dashboard where a user gets the
ingest token + Home Assistant bridge config to link their own Frigate. Session-cookie
auth (separate from the relay-owner /admin area)."""
import os

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from . import accounts, db

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
    return RedirectResponse("/dashboard", status_code=303)


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
        },
    )


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
