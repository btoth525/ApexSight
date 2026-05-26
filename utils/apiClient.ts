import axios from "axios";
import { useAuthStore } from "@/stores/authStore";

export const apiClient = axios.create({
  timeout: 15000,
  headers: { "Content-Type": "application/json" },
});

apiClient.interceptors.request.use((config) => {
  const { token, baseUrl } = useAuthStore.getState();
  config.baseURL = `${baseUrl}/api`;
  if (token && token !== "session") {
    config.headers["Cookie"] = `frigate_token=${token}`;
  }
  config.headers["X-CSRF-TOKEN"] = "1";
  return config;
});

// No auto-logout on 401 — too aggressive. Frigate may return 401 for
// endpoints that don't exist yet (e.g. /notifications/register on a server
// that hasn't been patched), and we don't want background API calls to
// kick the user out of the app. The user can manually sign out from
// settings if their session actually expires.
