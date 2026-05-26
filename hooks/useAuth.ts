import { useEffect } from "react";
import { useRouter, useSegments } from "expo-router";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";

export function useAuth() {
  const { token, isLoading, initialize } = useAuthStore();
  const initSettings = useSettingsStore((s) => s.initialize);
  const router = useRouter();
  const segments = useSegments();

  useEffect(() => {
    initialize();
    initSettings();
  }, []);

  useEffect(() => {
    if (isLoading) return;
    const seg = segments[0] as string | undefined;
    const inAuthGroup = seg === "(auth)";
    const inBrowser   = seg === "browser";

    if (!token && !inAuthGroup) {
      // Not logged in and not already on login screen → go to login
      router.replace("/(auth)/login");
    } else if (token && !inBrowser) {
      // Logged in but not on browser yet (e.g. still on splash/index) → go to browser
      router.replace("/browser");
    }
  }, [token, isLoading, segments]);

  return { token, isLoading };
}
