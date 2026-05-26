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


def extract_base_url(sub: Any) -> Optional[str]:
    """Pull the base_url sent by the app at registration time."""
    if isinstance(sub, dict):
        url = sub.get("base_url")
        if isinstance(url, str) and url.startswith("http"):
            return url.rstrip("/")
    return None


class ExpoPushClient:
    """Background sender for Expo Push notifications."""

    def __init__(self, stop_event: threading.Event):
        self.stop_event = stop_event
        # Maps expo_token -> {"username": str, "base_url": str}
        self.registrations: dict[str, dict] = {}
        self.queue: queue.Queue = queue.Queue()
        self.worker = threading.Thread(
            target=self._process, daemon=True, name="expo_push_worker"
        )
        self.worker.start()

    # ------- token management -------

    def register_token(
        self, username: str, token: str, base_url: Optional[str] = None
    ) -> None:
        if not token or not token.startswith(EXPO_TOKEN_PREFIXES):
            return
        self.registrations[token] = {"username": username, "base_url": base_url}
        logger.info(
            f"Registered Expo Push token for {username} "
            f"(base_url={base_url}): {token[:30]}…"
        )

    def remove_token(self, token: str) -> None:
        if token in self.registrations:
            del self.registrations[token]
            logger.info(f"Removed invalid Expo Push token: {token[:30]}…")

    def all_tokens(self) -> list[str]:
        return list(self.registrations.keys())

    def base_url_for(self, token: str) -> Optional[str]:
        return self.registrations.get(token, {}).get("base_url")

    # ------- send -------

    def send_alert(
        self,
        title: str,
        body: str,
        data: Optional[dict] = None,
        thumb_id: Optional[str] = None,
        category: str = "FRIGATE_ALERT",
    ) -> None:
        """Queue a rich alert notification to all registered tokens."""
        tokens = self.all_tokens()
        if not tokens:
            return

        for i in range(0, len(tokens), 100):
            batch = tokens[i : i + 100]
            messages = []
            for token in batch:
                base_url = self.base_url_for(token)
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
                    "categoryId": category,
                }
                # Attach snapshot image using the app's registered Cloudflare URL
                if thumb_id and base_url:
                    image_url = f"{base_url}/api/notification-thumb/{thumb_id}"
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

    def stop(self) -> None:
        self.stop_event.set()
