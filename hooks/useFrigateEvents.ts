import { useEffect, useRef, useCallback } from "react";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";

type EventHandler = (data: unknown) => void;

export function useFrigateEvents(onEvent: EventHandler) {
  const wsRef = useRef<WebSocket | null>(null);
  const { baseUrl } = useAuthStore();
  const setWsConnected = useSettingsStore((s) => s.setWsConnected);
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  const connect = useCallback(() => {
    if (!baseUrl) return;
    const wsUrl = baseUrl.replace("https://", "wss://").replace("http://", "ws://") + "/ws";

    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;

    ws.onopen = () => { setWsConnected(true); };
    ws.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data);
        onEventRef.current(data);
      } catch {
        // ignore parse errors
      }
    };
    ws.onerror = () => { setWsConnected(false); };
    ws.onclose = () => {
      setWsConnected(false);
      setTimeout(connect, 3000);
    };
  }, [baseUrl, setWsConnected]);

  useEffect(() => {
    connect();
    return () => {
      wsRef.current?.close();
    };
  }, [connect]);
}
