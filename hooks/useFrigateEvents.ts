import { useEffect, useRef } from "react";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";

type EventHandler = (data: unknown) => void;

export function useFrigateEvents(onEvent: EventHandler) {
  const wsRef     = useRef<WebSocket | null>(null);
  const timerRef  = useRef<ReturnType<typeof setTimeout> | null>(null);
  const activeRef = useRef(false);
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  const { baseUrl, token } = useAuthStore();
  const setWsConnected = useSettingsStore((s) => s.setWsConnected);

  // Keep latest values accessible inside the stable closure below
  const baseUrlRef = useRef(baseUrl);
  const tokenRef   = useRef(token);
  baseUrlRef.current = baseUrl;
  tokenRef.current   = token;

  useEffect(() => {
    activeRef.current = true;

    function connect() {
      if (!activeRef.current || !baseUrlRef.current) return;
      const base = baseUrlRef.current
        .replace("https://", "wss://")
        .replace("http://", "ws://");
      const tok = tokenRef.current;
      const param = tok && tok !== "session"
        ? `?token=${encodeURIComponent(tok)}` : "";
      const url = `${base}/ws${param}`;

      const ws = new WebSocket(url);
      wsRef.current = ws;

      ws.onopen    = () => { if (activeRef.current) setWsConnected(true); };
      ws.onmessage = (e) => {
        try { onEventRef.current(JSON.parse(e.data)); } catch {}
      };
      ws.onerror   = () => { if (activeRef.current) setWsConnected(false); };
      ws.onclose   = () => {
        if (!activeRef.current) return;
        setWsConnected(false);
        timerRef.current = setTimeout(connect, 4000);
      };
    }

    connect();

    return () => {
      activeRef.current = false;
      if (timerRef.current) clearTimeout(timerRef.current);
      wsRef.current?.close();
      wsRef.current = null;
    };
  // Only restart the WebSocket when baseUrl or token actually change
  }, [baseUrl, token, setWsConnected]);
}
