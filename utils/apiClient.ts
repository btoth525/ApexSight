import axios from "axios";
import { useAuthStore } from "@/stores/authStore";

export const apiClient = axios.create({
  timeout: 15000,
  headers: { "Content-Type": "application/json" },
});

apiClient.interceptors.request.use((config) => {
  const { baseUrl } = useAuthStore.getState();
  config.baseURL = `${baseUrl}/api`;
  // iOS manages the frigate_token cookie automatically after login.
  // X-CSRF-TOKEN is required by Frigate for all mutating requests.
  config.headers["X-CSRF-TOKEN"] = "1";
  return config;
});

apiClient.interceptors.response.use(
  (r) => r,
  (err) => {
    if (err.response?.status === 401) {
      useAuthStore.getState().logout();
    }
    return Promise.reject(err);
  }
);
