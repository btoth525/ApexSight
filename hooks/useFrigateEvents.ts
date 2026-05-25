import { useEffect, useRef, useCallback } from "react";
import { useAuthStore } from "@/stores/authStore";

type EventHandler = (data: unknown) => void;

export function useFrigateEvents(onEvent: EventHandler) {
  const wsRef = useRef<WebSocket | null>(null);
  const { baseUrl } = useAuthStore();
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  const connect = useCallback(() => {
    if (!baseUrl) return;
    const wsUrl = baseUrl.replace("https://", "wss://").replace("http://", "ws://") + "/ws";

    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;

    ws.onopen = () => console.log("[WS] Connected");
    ws.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data);
        onEventRef.current(data);
      } catch {
        // ignore parse errors
      }
    };
    ws.onerror = (e) => console.warn("[WS] Error", e);
    ws.onclose = () => {
      console.log("[WS] Closed, reconnecting in 3s...");
      setTimeout(connect, 3000);
    };
  }, [baseUrl]);

  useEffect(() => {
    connect();
    return () => {
      wsRef.current?.close();
    };
  }, [connect]);
}
