"""Expo Push notification client.

Sends rich notifications to native mobile apps (iOS/Android) via Expo's
push gateway, which routes through APNs (Apple) and FCM (Google).
Works even when the mobile app is fully killed.

Drop this file into: frigate/comms/expo_push.py
"""

import json
import logging
import queue
import threading
import urllib.error
import urllib.request
from typing import Any, Optional

logger = logging.getLogger(__name__)

EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send"
EXPO_TOKEN_PREFIXES = ("ExponentPushToken[", "ExpoPushToken[")


def is_expo_token(sub: Any) -> bool:
    """Detect whether a saved subscription is an Expo Push Token."""
    if isinstance(sub, str):
        return sub.startswith(EXPO_TOKEN_PREFIXES)
    if isinstance(sub, dict):
        if sub.get("type") == "expo":
            return True
        endpoint = sub.get("endpoint") or ""
        if "exp.host" in endpoint:
            return True
        token = sub.get("token")
        if isinstance(token, str) and token.startswith(EXPO_TOKEN_PREFIXES):
            return True
    return False


def extract_expo_token(sub: Any) -> Optional[str]:
    """Pull the raw ExponentPushToken[...] string out of a subscription record."""
    if isinstance(sub, str) and sub.startswith(EXPO_TOKEN_PREFIXES):
        return sub
    if isinstance(sub, dict):
        token = sub.get("token")
        if isinstance(token, str) and token.startswith(EXPO_TOKEN_PREFIXES):
            return token
    return None


class ExpoPushClient:
    """Background sender for Expo Push notifications."""

    def __init__(self, stop_event: threading.Event):
        self.stop_event = stop_event
        self.tokens_by_user: dict[str, list[str]] = {}
        self.queue: queue.Queue = queue.Queue()
        self.worker = threading.Thread(
            target=self._process, daemon=True, name="expo_push_worker"
        )
        self.worker.start()

    # ------- token management -------

    def register_token(self, username: str, token: str) -> None:
        if not token or not token.startswith(EXPO_TOKEN_PREFIXES):
            return
        bucket = self.tokens_by_user.setdefault(username, [])
        if token not in bucket:
            bucket.append(token)
            logger.info(
                f"Registered Expo Push token for {username}: {token[:30]}…"
            )

    def remove_token(self, token: str) -> None:
        for tokens in self.tokens_by_user.values():
            if token in tokens:
                tokens.remove(token)
                logger.info(f"Removed invalid Expo Push token: {token[:30]}…")

    def all_tokens(self) -> list[str]:
        return [t for tokens in self.tokens_by_user.values() for t in tokens]

    # ------- send -------

    def send(
        self,
        title: str,
        body: str,
        data: Optional[dict] = None,
        image_url: Optional[str] = None,
        category: Optional[str] = None,
    ) -> None:
        """Queue a notification to all registered tokens."""
        tokens = self.all_tokens()
        if not tokens:
            return

        for i in range(0, len(tokens), 100):  # Expo accepts ≤100 per request
            batch = tokens[i : i + 100]
            messages = []
            for token in batch:
                msg: dict[str, Any] = {
                    "to": token,
                    "title": title,
                    "body": body,
                    "data": data or {},
                    "sound": "default",
                    "priority": "high",
                    "channelId": "alerts",
                    "mutableContent": True,
                    "_displayInForeground": True,
                }
                if category:
                    msg["categoryId"] = category
                if image_url:
                    # iOS rich notification with image (lock-screen preview)
                    msg["richContent"] = {"image": image_url}
                    msg["attachments"] = [{"url": image_url, "type": "image"}]
                messages.append(msg)
            self.queue.put(messages)

    def _process(self) -> None:
        while not self.stop_event.is_set():
            try:
                messages = self.queue.get(timeout=1)
            except queue.Empty:
                continue
            try:
                self._send_batch(messages)
            except Exception:
                logger.exception("Expo Push send_batch failed")

    def _send_batch(self, messages: list[dict]) -> None:
        try:
            req = urllib.request.Request(
                EXPO_PUSH_URL,
                data=json.dumps(messages).encode("utf-8"),
                headers={
                    "Accept": "application/json",
                    "Accept-Encoding": "gzip, deflate",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            self._handle_tickets(payload, messages)
        except urllib.error.HTTPError as e:
            logger.warning(f"Expo Push HTTP error {e.code}")
        except urllib.error.URLError as e:
            logger.warning(f"Expo Push network error: {e}")

    def _handle_tickets(self, payload: dict, messages: list[dict]) -> None:
        tickets = payload.get("data") or []
        for i, ticket in enumerate(tickets):
            if i >= len(messages):
                break
            if ticket.get("status") != "error":
                continue
            details = ticket.get("details") or {}
            err = details.get("error", "")
            if err == "DeviceNotRegistered":
                self.remove_token(messages[i]["to"])
            else:
                logger.warning(
                    f"Expo ticket error for {messages[i]['to'][:20]}…: {err}"
                )
