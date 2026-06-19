"""Tiny SQLite layer for the relay.

Three concerns:
  * config   — key/value store for the uploaded APNs credentials + settings
  * devices  — every iOS device token, tied to its household pairing code
  * (pairings are implicit: a pairing code is just the set of devices sharing it)
"""
import sqlite3
import time
from contextlib import contextmanager
from typing import Optional

from . import config


def init() -> None:
    with _conn() as c:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS config (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS devices (
                device_token TEXT PRIMARY KEY,
                pairing_code TEXT NOT NULL,
                environment  TEXT NOT NULL DEFAULT 'production',
                platform     TEXT,
                updated_at   INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_devices_pairing ON devices(pairing_code);
            CREATE TABLE IF NOT EXISTS recap_events (
                pairing_code TEXT NOT NULL,
                event_id     TEXT NOT NULL,
                camera       TEXT,
                label        TEXT,
                sub_label    TEXT,
                ts           REAL NOT NULL,
                PRIMARY KEY (pairing_code, event_id)
            );
            CREATE INDEX IF NOT EXISTS idx_recap_ts ON recap_events(pairing_code, ts);
            CREATE TABLE IF NOT EXISTS activity_tokens (
                token        TEXT PRIMARY KEY,
                pairing_code TEXT NOT NULL,
                kind         TEXT NOT NULL DEFAULT 'start',
                environment  TEXT NOT NULL DEFAULT 'production',
                updated_at   INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_activity_pairing ON activity_tokens(pairing_code, kind);
            CREATE TABLE IF NOT EXISTS accounts (
                id            TEXT PRIMARY KEY,
                email         TEXT UNIQUE,
                password_hash TEXT,
                apple_sub     TEXT UNIQUE,
                ingest_token  TEXT NOT NULL UNIQUE,
                created_at    INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_accounts_ingest ON accounts(ingest_token);
            """
        )


@contextmanager
def _conn():
    conn = sqlite3.connect(config.DB_PATH, timeout=5.0)
    conn.row_factory = sqlite3.Row
    # The MQTT bridge runs in a second process and writes recap_events to the same DB.
    # WAL lets a reader and a writer coexist, and busy_timeout makes a writer wait for
    # a lock instead of raising "database is locked" — together these stop lost recap
    # rows and 500s under concurrent access.
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# ---- config key/value -------------------------------------------------------

def get_config(key: str, default: Optional[str] = None) -> Optional[str]:
    with _conn() as c:
        row = c.execute("SELECT value FROM config WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default


def set_config(key: str, value: str) -> None:
    with _conn() as c:
        c.execute(
            "INSERT INTO config(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )


def all_config() -> dict:
    with _conn() as c:
        return {r["key"]: r["value"] for r in c.execute("SELECT key, value FROM config")}


# ---- devices ----------------------------------------------------------------

def upsert_device(device_token: str, pairing_code: str, environment: str, platform: str = "") -> None:
    with _conn() as c:
        c.execute(
            "INSERT INTO devices(device_token, pairing_code, environment, platform, updated_at) "
            "VALUES(?, ?, ?, ?, ?) "
            "ON CONFLICT(device_token) DO UPDATE SET "
            "  pairing_code = excluded.pairing_code, "
            "  environment  = excluded.environment, "
            "  platform     = excluded.platform, "
            "  updated_at   = excluded.updated_at",
            (device_token, pairing_code, environment, platform, int(time.time())),
        )


def delete_device(device_token: str) -> None:
    with _conn() as c:
        c.execute("DELETE FROM devices WHERE device_token = ?", (device_token,))


def devices_for(pairing_code: str) -> list[sqlite3.Row]:
    with _conn() as c:
        return c.execute(
            "SELECT device_token, environment, platform, updated_at FROM devices "
            "WHERE pairing_code = ?",
            (pairing_code,),
        ).fetchall()


def all_devices() -> list[sqlite3.Row]:
    with _conn() as c:
        return c.execute(
            "SELECT device_token, pairing_code, environment, platform, updated_at "
            "FROM devices ORDER BY updated_at DESC"
        ).fetchall()


def device_count() -> int:
    with _conn() as c:
        return c.execute("SELECT COUNT(*) AS n FROM devices").fetchone()["n"]


# ---- recap events (accumulated from the MQTT stream by the bridge) -----------

def recap_events_between(pairing_code: str, start_ts: float, end_ts: float) -> list[sqlite3.Row]:
    with _conn() as c:
        return c.execute(
            "SELECT camera, label, sub_label, ts FROM recap_events "
            "WHERE pairing_code = ? AND ts >= ? AND ts <= ?",
            (pairing_code, start_ts, end_ts),
        ).fetchall()


def prune_recap_events(before_ts: float) -> None:
    with _conn() as c:
        c.execute("DELETE FROM recap_events WHERE ts < ?", (before_ts,))


# ---- Live Activity push tokens ----------------------------------------------

def upsert_activity_token(token: str, pairing_code: str, kind: str, environment: str) -> None:
    with _conn() as c:
        c.execute(
            "INSERT INTO activity_tokens(token, pairing_code, kind, environment, updated_at) "
            "VALUES(?, ?, ?, ?, ?) "
            "ON CONFLICT(token) DO UPDATE SET "
            "  pairing_code = excluded.pairing_code, "
            "  kind         = excluded.kind, "
            "  environment  = excluded.environment, "
            "  updated_at   = excluded.updated_at",
            (token, pairing_code, kind, environment, int(time.time())),
        )


def activity_tokens_for(pairing_code: str, kind: str) -> list[sqlite3.Row]:
    with _conn() as c:
        return c.execute(
            "SELECT token, environment FROM activity_tokens WHERE pairing_code = ? AND kind = ?",
            (pairing_code, kind),
        ).fetchall()


def delete_activity_token(token: str) -> None:
    with _conn() as c:
        c.execute("DELETE FROM activity_tokens WHERE token = ?", (token,))


def prune_activity_tokens(before_ts: float) -> None:
    with _conn() as c:
        c.execute("DELETE FROM activity_tokens WHERE updated_at < ?", (int(before_ts),))


# ---- accounts ---------------------------------------------------------------

def create_account(
    account_id: str,
    ingest_token: str,
    email: Optional[str] = None,
    password_hash: Optional[str] = None,
    apple_sub: Optional[str] = None,
) -> None:
    with _conn() as c:
        c.execute(
            "INSERT INTO accounts(id, email, password_hash, apple_sub, ingest_token, created_at) "
            "VALUES(?, ?, ?, ?, ?, ?)",
            (account_id, email, password_hash, apple_sub, ingest_token, int(time.time())),
        )


def account_by_email(email: str) -> Optional[sqlite3.Row]:
    with _conn() as c:
        return c.execute("SELECT * FROM accounts WHERE email = ?", (email,)).fetchone()


def account_by_apple_sub(apple_sub: str) -> Optional[sqlite3.Row]:
    with _conn() as c:
        return c.execute("SELECT * FROM accounts WHERE apple_sub = ?", (apple_sub,)).fetchone()


def account_by_id(account_id: str) -> Optional[sqlite3.Row]:
    with _conn() as c:
        return c.execute("SELECT * FROM accounts WHERE id = ?", (account_id,)).fetchone()


def set_account_email(account_id: str, email: str) -> None:
    with _conn() as c:
        c.execute("UPDATE accounts SET email = ? WHERE id = ?", (email, account_id))


def set_ingest_token(account_id: str, ingest_token: str) -> None:
    with _conn() as c:
        c.execute("UPDATE accounts SET ingest_token = ? WHERE id = ?", (ingest_token, account_id))


def delete_account(account_id: str) -> None:
    """Remove the account and everything routed by its ingest token."""
    with _conn() as c:
        row = c.execute("SELECT ingest_token FROM accounts WHERE id = ?", (account_id,)).fetchone()
        if not row:
            return
        token = row["ingest_token"]
        c.execute("DELETE FROM devices WHERE pairing_code = ?", (token,))
        c.execute("DELETE FROM activity_tokens WHERE pairing_code = ?", (token,))
        c.execute("DELETE FROM config WHERE key IN (?, ?, ?)",
                  (f"gate:{token}", f"style:{token}", f"recap:{token}"))
        c.execute("DELETE FROM accounts WHERE id = ?", (account_id,))
