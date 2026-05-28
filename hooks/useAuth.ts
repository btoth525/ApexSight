import { useEffect } from "react";
import { useRouter, useSegments } from "expo-router";
import { useAuthStore } from "@/stores/authStore";

export function useAuth() {
  const { token, isLoading, initialize } = useAuthStore();
  const router = useRouter();
  const segments = useSegments();

  useEffect(() => {
    initialize();
  }, []);

  // Routing — only ever redirect when we know for sure which state we're in.
  // We deliberately do NOT probe /api/config on cold start. If the stored JWT
  // has gone stale (e.g. Frigate restarted), Frigate's own PWA will show its
  // login page inside the WebView — the user can re-authenticate there, or
  // press Sign Out in Apex settings for a full re-login. Auto-logout here was
  // the root cause of the "exit app → back to login screen" loop.
  useEffect(() => {
    if (isLoading) return;
    const seg = segments[0] as string | undefined;
    const inAuthGroup = seg === "(auth)";
    const inBrowser   = seg === "browser";

    // Already on the right screen — never re-replace, it remounts the component
    // and resets loading state, causing a black screen loop.
    if (token && inBrowser) return;
    if (!token && inAuthGroup) return;

    if (!token) {
      router.replace("/(auth)/login");
    } else {
      router.replace("/browser");
    }
  // Intentionally omitting `segments` — we only care when token/isLoading changes,
  // not on every expo-router segment update during navigation.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token, isLoading]);

  return { token, isLoading };
}
