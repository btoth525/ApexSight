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
    const inAuthGroup = segments[0] === "(auth)";
    if (!token && !inAuthGroup) {
      router.replace("/(auth)/login");
    } else if (token && inAuthGroup) {
      router.replace("/browser");
    }
  }, [token, isLoading, segments]);

  return { token, isLoading };
}
