"""Transactional email (verification + password reset) over SMTP.

Uses the stdlib (no extra dependency). Configure APEX_SMTP_* env vars; if unset,
`send_email` is a no-op that returns False so callers degrade gracefully.
"""
import smtplib
import ssl
from email.message import EmailMessage

from . import config


def send_email(to: str, subject: str, text: str, html: str | None = None) -> bool:
    if not config.smtp_configured() or not to:
        return False
    msg = EmailMessage()
    msg["From"] = config.SMTP_FROM
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(text)
    if html:
        msg.add_alternative(html, subtype="html")
    try:
        with smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT, timeout=15) as server:
            server.starttls(context=ssl.create_default_context())
            if config.SMTP_USER:
                server.login(config.SMTP_USER, config.SMTP_PASSWORD)
            server.send_message(msg)
        return True
    except Exception as exc:
        print("[mail] send failed:", exc, flush=True)
        return False


def _wrap(title: str, body_html: str, button_label: str, link: str) -> str:
    return f"""\
<div style="background:#05060a;padding:32px 0;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">
  <div style="max-width:480px;margin:0 auto;background:#0e1118;border:1px solid #1d2230;border-radius:20px;padding:32px;color:#f3f5f8">
    <div style="font-weight:900;font-size:20px;margin-bottom:8px">ApexSight</div>
    <h1 style="font-size:22px;margin:8px 0 14px">{title}</h1>
    <p style="color:#9aa3b2;font-size:15px;line-height:1.5">{body_html}</p>
    <a href="{link}" style="display:inline-block;margin:20px 0;background:#63d2ff;color:#04121f;
       font-weight:800;text-decoration:none;padding:13px 22px;border-radius:999px">{button_label}</a>
    <p style="color:#6b7280;font-size:12px;line-height:1.5">If the button doesn't work, paste this link
       into your browser:<br><span style="color:#63d2ff;word-break:break-all">{link}</span></p>
  </div>
</div>"""


def send_verification(to: str, link: str) -> bool:
    return send_email(
        to,
        "Verify your ApexSight email",
        f"Confirm your email to finish setting up ApexSight:\n\n{link}\n\nThis link expires in 24 hours.",
        _wrap("Confirm your email",
              "Tap below to verify your email and finish setting up ApexSight. This link expires in 24 hours.",
              "Verify email", link),
    )


def send_password_reset(to: str, link: str) -> bool:
    return send_email(
        to,
        "Reset your ApexSight password",
        f"Reset your ApexSight password:\n\n{link}\n\nThis link expires in 1 hour. If you didn't ask, ignore this.",
        _wrap("Reset your password",
              "Tap below to choose a new password. This link expires in 1 hour. If you didn't request it, you can ignore this email.",
              "Reset password", link),
    )
