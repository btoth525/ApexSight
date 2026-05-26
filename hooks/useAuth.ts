import { useEffect, useRef } from "react";
import { useRouter, useSegments } from "expo-router";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";
import { apiClient } from "@/utils/apiClient";

export function useAuth() {
  const { token, isLoading, initialize } = useAuthStore();
  const initSettings = useSettingsStore((s) => s.initialize);
  const router = useRouter();
  const segments = useSegments();

  // Validation must run at most once per app cold start. This ref lives in
  // _layout.tsx (which never unmounts), so it persists across logins/logouts.
  // After the first validation, no further API probes run — fresh-login
  // tokens are trusted implicitly, which is what prevents the loop.
  const validatedRef = useRef(false);

  useEffect(() => {
    initialize();
    initSettings();
  }, []);

  // One-time stored-token validation on cold start.
  // If Frigate was restarted while the app was closed, its JWT secret has
  // rotated and the stored token is invalid. We probe /api/config (which
  // exists on every Frigate version) — a 401 means the token is dead and
  // we should clean-logout so the user lands on the login screen.
  useEffect(() => {
    if (isLoading) return;            // wait for initialize() to finish
    if (validatedRef.current) return; // already ran this app session
    validatedRef.current = true;
    if (!token) return;               // nothing to validate
    apiClient.get("/config").catch((err) => {
      if (err.response?.status === 401) {
        useAuthStore.getState().logout();
      }
    });
  }, [isLoading, token]);

  // Routing — covers all six (token × screen) states without overlap.
  useEffect(() => {
    if (isLoading) return;
    const seg = segments[0] as string | undefined;
    const inAuthGroup = seg === "(auth)";
    const inBrowser   = seg === "browser";

    if (!token && !inAuthGroup) {
      router.replace("/(auth)/login");
    } else if (token && !inBrowser) {
      router.replace("/browser");
    }
  }, [token, isLoading, segments]);

  return { token, isLoading };
}
