import { useCallback, useEffect, useRef, useState } from "react";
import { Platform } from "react-native";
import * as SecureStore from "expo-secure-store";

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

function generateUUID(): string {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
  });
}

// Lazy-load native modules so a missing entitlement/provisioning issue
// never crashes the app — CallKit just silently won't work.
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
    // idempotent — safe to call multiple times
  }
}

export function useDoorbellCall({ onAnswer, onEndCall }: Options) {
  const [voipToken, setVoipToken] = useState<string | null>(null);
  const activeCallRef = useRef<ActiveCall | null>(null);

  const onAnswerRef = useRef(onAnswer);
  const onEndCallRef = useRef(onEndCall);
  useEffect(() => { onAnswerRef.current = onAnswer; }, [onAnswer]);
  useEffect(() => { onEndCallRef.current = onEndCall; }, [onEndCall]);

  useEffect(() => {
    if (Platform.OS !== "ios") return;

    // Load cached token immediately (shows in settings before re-registration)
    SecureStore.getItemAsync(VOIP_TOKEN_KEY).then((t) => {
      if (t) setVoipToken(t);
    }).catch(() => {});

    const RNCallKeep = getCallKeep();
    const VoipPush = getVoipPush();

    // If either native module failed to load, bail out gracefully —
    // the rest of the app continues to work normally.
    if (!RNCallKeep || !VoipPush) return;

    try {
      setupCallKeep(RNCallKeep);
      VoipPush.registerVoipToken();
    } catch {
      return;
    }

    const handleToken = (token: string) => {
      try {
        setVoipToken(token);
        SecureStore.setItemAsync(VOIP_TOKEN_KEY, token).catch(() => {});
      } catch {}
    };

    const handlePush = (notification: object) => {
      try {
        const n = notification as { data?: { camera?: string; caller?: string } };
        setupCallKeep(RNCallKeep);
        const camera = n?.data?.camera ?? "doorbell";
        const caller = n?.data?.caller ?? "Front Door";
        const callUUID = generateUUID();
        activeCallRef.current = { callUUID, cameraName: camera, callerName: caller };
        RNCallKeep.displayIncomingCall(callUUID, caller, caller, "generic", true);
      } catch {}
    };

    const handleAnswer = ({ callUUID }: { callUUID: string }) => {
      try {
        const call = activeCallRef.current;
        if (call && call.callUUID === callUUID) onAnswerRef.current(call);
      } catch {}
    };

    const handleEnd = ({ callUUID }: { callUUID: string }) => {
      try {
        activeCallRef.current = null;
        onEndCallRef.current(callUUID);
      } catch {}
    };

    try {
      VoipPush.addEventListener("register", handleToken);
      VoipPush.addEventListener("notification", handlePush);
      RNCallKeep.addEventListener("answerCall", handleAnswer);
      RNCallKeep.addEventListener("endCall", handleEnd);
    } catch {}

    return () => {
      try {
        VoipPush.removeEventListener("register");
        VoipPush.removeEventListener("notification");
        RNCallKeep.removeEventListener("answerCall");
        RNCallKeep.removeEventListener("endCall");
      } catch {}
    };
  }, []);

  const endCall = useCallback((callUUID?: string) => {
    try {
      const RNCallKeep = getCallKeep();
      if (!RNCallKeep) return;
      const uuid = callUUID ?? activeCallRef.current?.callUUID;
      if (uuid) {
        RNCallKeep.endCall(uuid);
        activeCallRef.current = null;
      }
    } catch {}
  }, []);

  return { voipToken, endCall };
}
