import { useEffect, useRef } from "react";
import { Platform } from "react-native";
import * as Notifications from "expo-notifications";
import Constants from "expo-constants";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";
import { apiClient } from "@/utils/apiClient";

/**
 * After login, ask iOS for an Expo Push Token and register it with the
 * Frigate server so it can push notifications via APNs even when the
 * app is fully killed.
 */
export function useExpoPushRegistration() {
  const { token, baseUrl } = useAuthStore();
  const { notificationsEnabled } = useSettingsStore();
  const lastRegistered = useRef<string | null>(null);

  useEffect(() => {
    if (!token || token === "session" || !baseUrl || !notificationsEnabled) return;
    if (Platform.OS !== "ios" && Platform.OS !== "android") return;

    const register = async () => {
      try {
        // Make sure we have permission
        let { status } = await Notifications.getPermissionsAsync();
        if (status !== "granted") {
          const req = await Notifications.requestPermissionsAsync();
          if (req.status !== "granted") return;
        }

        // Get the Expo Push Token (looks like "ExponentPushToken[xxx]")
        const projectId =
          Constants.expoConfig?.extra?.eas?.projectId ??
          Constants.easConfig?.projectId;
        const tokenResp = await Notifications.getExpoPushTokenAsync(
          projectId ? { projectId } : undefined,
        );
        const pushToken = tokenResp.data;
        if (!pushToken) return;

        // Skip if we already registered the same token
        const fingerprint = `${baseUrl}::${pushToken}`;
        if (lastRegistered.current === fingerprint) return;

        await apiClient.post("/notifications/register", {
          sub: {
            type: "expo",
            token: pushToken,
            platform: Platform.OS,
          },
        });
        lastRegistered.current = fingerprint;
      } catch {
        // Silent — registration will retry on next mount
      }
    };

    register();
  }, [token, baseUrl, notificationsEnabled]);
}
