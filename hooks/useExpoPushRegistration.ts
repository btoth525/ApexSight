import { useCallback, useEffect, useRef } from "react";
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
  const { notificationsEnabled, setPushTokenRegistered } = useSettingsStore();
  const lastRegistered = useRef<string | null>(null);

  const register = useCallback(async (force = false) => {
    if (!token || token === "session" || !baseUrl || !notificationsEnabled) return;
    if (Platform.OS !== "ios" && Platform.OS !== "android") return;

    try {
      let { status } = await Notifications.getPermissionsAsync();
      if (status !== "granted") {
        const req = await Notifications.requestPermissionsAsync();
        if (req.status !== "granted") return;
      }

      const projectId =
        Constants.expoConfig?.extra?.eas?.projectId ??
        Constants.easConfig?.projectId;
      const tokenResp = await Notifications.getExpoPushTokenAsync(
        projectId ? { projectId } : undefined,
      );
      const pushToken = tokenResp.data;
      if (!pushToken) return;

      const fingerprint = `${baseUrl}::${pushToken}`;
      if (!force && lastRegistered.current === fingerprint) return;

      await apiClient.post("/notifications/register", {
        sub: {
          type: "expo",
          token: pushToken,
          platform: Platform.OS,
          base_url: baseUrl,
        },
      });
      lastRegistered.current = fingerprint;
      setPushTokenRegistered(true);
    } catch {
      setPushTokenRegistered(false);
    }
  }, [token, baseUrl, notificationsEnabled]);

  useEffect(() => { register(); }, [register]);

  const retryRegister = useCallback(() => register(true), [register]);
  return { retryRegister };
}
