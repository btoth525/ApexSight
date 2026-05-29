import { useCallback, useEffect, useRef, useState } from "react";
import { Platform } from "react-native";
import * as SecureStore from "expo-secure-store";
import { useAuthStore } from "@/stores/authStore";

export const VOIP_TOKEN_KEY = "apex_voip_push_token";

export type ActiveCall = {
  callUUID: string;
  cameraName: string;
  callerName: string;
};

type Options = {
  onAnswer: (call: ActiveCall) => void;
  onEndCall: (callUUID: string) => void;
};

// Lazy-load native modules so any linking/entitlement issue degrades
// gracefully instead of crashing the whole app.
function getCallKeep() {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    return require("react-native-callkeep").default;
  } catch {
    return null;
  }
}

function getVoipPush() {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    return require("react-native-voip-push-notification").default;
  } catch {
    return null;
  }
}

function setupCallKeep(RNCallKeep: NonNullable<ReturnType<typeof getCallKeep>>) {
  try {
    RNCallKeep.setup({
      ios: {
        appName: "Apex",
        supportsVideo: true,
        maximumCallGroups: "1",
        maximumCallsPerCallGroup: "1",
      },
      android: {
        alertTitle: "Permissions required",
        alertDescription: "Allow Apex to access phone accounts",
        cancelButton: "Cancel",
        okButton: "OK",
        additionalPermissions: [],
      },
    });
    RNCallKeep.setAvailable(true);
  } catch {
    // idempotent — safe to call repeatedly
  }
}

export function useDoorbellCall({ onAnswer, onEndCall }: Options) {
  const [voipToken, setVoipToken] = useState<string | null>(null);

  // uuid → camera, populated by the VoIP "notification" payload. The native
  // AppDelegate already showed the CallKit screen via reportNewIncomingCall;
  // here we just need to know which camera to open when the call is answered.
  const cameraByUUID = useRef<Record<string, string>>({});
  const lastCameraRef = useRef<string>("doorbell");

  const onAnswerRef = useRef(onAnswer);
  const onEndCallRef = useRef(onEndCall);
  useEffect(() => { onAnswerRef.current = onAnswer; }, [onAnswer]);
  useEffect(() => { onEndCallRef.current = onEndCall; }, [onEndCall]);

  useEffect(() => {
    if (Platform.OS !== "ios") return;

    SecureStore.getItemAsync(VOIP_TOKEN_KEY)
      .then((t) => { if (t) setVoipToken(t); })
      .catch(() => {});

    const RNCallKeep = getCallKeep();
    const VoipPush = getVoipPush();
    if (!RNCallKeep || !VoipPush) return;

    try {
      setupCallKeep(RNCallKeep);
      VoipPush.registerVoipToken();
    } catch {
      return;
    }

    // ── Helpers ────────────────────────────────────────────────────────────
    const recordCamera = (payload: { uuid?: string; camera?: string }) => {
      const camera = payload?.camera ?? "doorbell";
      lastCameraRef.current = camera;
      if (payload?.uuid) cameraByUUID.current[payload.uuid] = camera;
    };

    const doAnswer = (callUUID: string) => {
      const camera = cameraByUUID.current[callUUID] ?? lastCameraRef.current;
      onAnswerRef.current({ callUUID, cameraName: camera, callerName: "Front Door" });
    };

    // ── VoIP push token ──────────────────────────────────────────────────
    const handleToken = (token: string) => {
      try {
        setVoipToken(token);
        SecureStore.setItemAsync(VOIP_TOKEN_KEY, token).catch(() => {});
      } catch {}
    };

    // ── Incoming VoIP push payload (CallKit UI already shown natively) ─────
    const handlePush = (notification: object) => {
      try {
        const payload = notification as { uuid?: string; camera?: string };
        recordCamera(payload);
        // Pre-warm go2rtc: open a WebSocket immediately so go2rtc starts
        // buffering the RTSP stream before the user taps Accept. By the time
        // they answer, ICE is already checked and a keyframe is buffered.
        const { baseUrl, token } = useAuthStore.getState();
        if (baseUrl) {
          try {
            const url = new URL(baseUrl);
            const proto = url.protocol === "https:" ? "wss:" : "ws:";
            const cam = encodeURIComponent(payload.camera ?? "doorbell_twoway");
            const tok = token ? `&token=${encodeURIComponent(token)}` : "";
            const ws = new WebSocket(`${proto}//${url.host}/live/webrtc/api/ws?src=${cam}${tok}`);
            setTimeout(() => { try { ws.close(); } catch {} }, 10000);
          } catch {}
        }
      } catch {}
    };

    // ── Call answered ──────────────────────────────────────────────────────
    const handleAnswer = ({ callUUID }: { callUUID: string }) => {
      try { doAnswer(callUUID); } catch {}
    };

    // ── Call ended / declined ────────────────────────────────────────────
    const handleEnd = ({ callUUID }: { callUUID: string }) => {
      try {
        delete cameraByUUID.current[callUUID];
        onEndCallRef.current(callUUID);
      } catch {}
    };

    // ── Cold start: events that fired before JS was ready ──────────────────
    // When the app is launched by answering the call, RNCallKeep buffers the
    // events and replays them here as [{ name, data }].
    const handleDidLoad = (events: { name: string; data: any }[]) => {
      try {
        if (!Array.isArray(events)) return;
        for (const e of events) {
          if (e.name === "RNCallKeepAnswerCall" && e.data?.callUUID) {
            doAnswer(e.data.callUUID);
          }
        }
      } catch {}
    };

    try {
      VoipPush.addEventListener("register", handleToken);
      VoipPush.addEventListener("notification", handlePush);
      RNCallKeep.addEventListener("answerCall", handleAnswer);
      RNCallKeep.addEventListener("endCall", handleEnd);
      RNCallKeep.addEventListener("didLoadWithEvents", handleDidLoad);
    } catch {}

    return () => {
      try {
        VoipPush.removeEventListener("register");
        VoipPush.removeEventListener("notification");
        RNCallKeep.removeEventListener("answerCall");
        RNCallKeep.removeEventListener("endCall");
        RNCallKeep.removeEventListener("didLoadWithEvents");
      } catch {}
    };
  }, []);

  const endCall = useCallback((callUUID?: string) => {
    try {
      const RNCallKeep = getCallKeep();
      if (!RNCallKeep) return;
      if (callUUID) {
        RNCallKeep.endCall(callUUID);
        delete cameraByUUID.current[callUUID];
      } else {
        // End any active call (best effort)
        for (const uuid of Object.keys(cameraByUUID.current)) {
          RNCallKeep.endCall(uuid);
          delete cameraByUUID.current[uuid];
        }
      }
    } catch {}
  }, []);

  return { voipToken, endCall };
}
