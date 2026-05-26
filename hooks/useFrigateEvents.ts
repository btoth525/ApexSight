import { useEffect, useRef, useCallback } from "react";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";

type EventHandler = (data: unknown) => void;

export function useFrigateEvents(onEvent: EventHandler) {
  const wsRef    = useRef<WebSocket | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const activeRef = useRef(false);
  const { baseUrl, token } = useAuthStore();
  const setWsConnected = useSettingsStore((s) => s.setWsConnected);
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  const connect = useCallback(() => {
    if (!activeRef.current || !baseUrl) return;
    // Pass token as query param — React Native WebSocket doesn't auto-send cookies
    const wsBase = baseUrl.replace("https://", "wss://").replace("http://", "ws://");
    const tokenParam = token && token !== "session" ? `?token=${encodeURIComponent(token)}` : "";
    const wsUrl = `${wsBase}/ws${tokenParam}`;

    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;

    ws.onopen = () => { if (activeRef.current) setWsConnected(true); };
    ws.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data);
        onEventRef.current(data);
      } catch {}
    };
    ws.onerror = () => { if (activeRef.current) setWsConnected(false); };
    ws.onclose = () => {
      if (!activeRef.current) return;
      setWsConnected(false);
      timerRef.current = setTimeout(connect, 4000);
    };
  }, [baseUrl, token, setWsConnected]);

  useEffect(() => {
    activeRef.current = true;
    connect();
    return () => {
      activeRef.current = false;
      if (timerRef.current) clearTimeout(timerRef.current);
      wsRef.current?.close();
      wsRef.current = null;
    };
  }, [connect]);
}
