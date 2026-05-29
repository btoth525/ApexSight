import { useCallback, useEffect, useRef, useState } from "react";
import { Platform } from "react-native";
import * as SecureStore from "expo-secure-store";
import RNCallKeep from "react-native-callkeep";
import VoipPushNotification from "react-native-voip-push-notification";

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

function setupCallKeep() {
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
    // setup may throw if already initialized — safe to ignore
  }
}

export function useDoorbellCall({ onAnswer, onEndCall }: Options) {
  const [voipToken, setVoipToken] = useState<string | null>(null);
  const activeCallRef = useRef<ActiveCall | null>(null);

  // Stable refs so push handler (which may fire before re-renders) always
  // calls the latest version of the callbacks without re-registering listeners.
  const onAnswerRef = useRef(onAnswer);
  const onEndCallRef = useRef(onEndCall);
  useEffect(() => { onAnswerRef.current = onAnswer; }, [onAnswer]);
  useEffect(() => { onEndCallRef.current = onEndCall; }, [onEndCall]);

  useEffect(() => {
    if (Platform.OS !== "ios") return;

    setupCallKeep();

    // Load cached token immediately (shows in settings before re-registration)
    SecureStore.getItemAsync(VOIP_TOKEN_KEY).then((t) => {
      if (t) setVoipToken(t);
    });

    VoipPushNotification.registerVoipToken();

    const handleToken = (token: string) => {
      setVoipToken(token);
      SecureStore.setItemAsync(VOIP_TOKEN_KEY, token).catch(() => {});
    };

    // Payload sent by voip_push.py: { "camera": "doorbell", "caller": "Front Door" }
    const handlePush = (notification: object) => {
      const n = notification as { data?: { camera?: string; caller?: string } };
      // Ensure CallKit is initialized (critical for killed-state wakeup)
      setupCallKeep();

      const camera = n?.data?.camera ?? "doorbell";
      const caller = n?.data?.caller ?? "Front Door";
      const callUUID = generateUUID();

      activeCallRef.current = { callUUID, cameraName: camera, callerName: caller };

      RNCallKeep.displayIncomingCall(
        callUUID,
        caller,    // handle (shown as caller identifier)
        caller,    // localizedCallerName
        "generic", // handleType
        true,      // hasVideo
      );
    };

    const handleAnswer = ({ callUUID }: { callUUID: string }) => {
      const call = activeCallRef.current;
      if (call && call.callUUID === callUUID) {
        onAnswerRef.current(call);
      }
    };

    const handleEnd = ({ callUUID }: { callUUID: string }) => {
      activeCallRef.current = null;
      onEndCallRef.current(callUUID);
    };

    VoipPushNotification.addEventListener("register", handleToken);
    VoipPushNotification.addEventListener("notification", handlePush);
    RNCallKeep.addEventListener("answerCall", handleAnswer);
    RNCallKeep.addEventListener("endCall", handleEnd);

    return () => {
      VoipPushNotification.removeEventListener("register");
      VoipPushNotification.removeEventListener("notification");
      RNCallKeep.removeEventListener("answerCall");
      RNCallKeep.removeEventListener("endCall");
    };
  }, []); // empty deps — callbacks accessed via refs

  const endCall = useCallback((callUUID?: string) => {
    const uuid = callUUID ?? activeCallRef.current?.callUUID;
    if (uuid) {
      RNCallKeep.endCall(uuid);
      activeCallRef.current = null;
    }
  }, []);

  return { voipToken, endCall };
}
