import { create } from "zustand";
import * as SecureStore from "expo-secure-store";
import CookieManager from "@react-native-cookies/cookies";
import { appGroup } from "@/utils/appGroup";

type AuthState = {
  token: string | null;
  username: string | null;
  baseUrl: string;
  isLoading: boolean;
  setAuth: (token: string, username: string) => Promise<void>;
  setBaseUrl: (url: string) => Promise<void>;
  logout: () => Promise<void>;
  initialize: () => Promise<void>;
};

export const useAuthStore = create<AuthState>((set, get) => ({
  token: null,
  username: null,
  baseUrl: "",
  isLoading: true,

  initialize: async () => {
    const [token, username, baseUrl] = await Promise.all([
      SecureStore.getItemAsync("frigate_token"),
      SecureStore.getItemAsync("frigate_username"),
      SecureStore.getItemAsync("frigate_base_url"),
    ]);
    const url = baseUrl ?? "";
    if (token && url) {
      appGroup.set("frigate_token", token);
      try {
        await CookieManager.set(url, {
          name: "frigate_token",
          value: token,
          path: "/",
          domain: new URL(url).hostname,
          httpOnly: true,
          secure: url.startsWith("https"),
          version: "1",
        });
      } catch {}
    }
    if (baseUrl) appGroup.set("frigate_base_url", baseUrl);
    set({ token, username, baseUrl: url, isLoading: false });
  },

  setAuth: async (token, username) => {
    await Promise.all([
      SecureStore.setItemAsync("frigate_token", token),
      SecureStore.setItemAsync("frigate_username", username),
    ]);
    const url = get().baseUrl;
    if (url) {
      try {
        await CookieManager.set(url, {
          name: "frigate_token",
          value: token,
          path: "/",
          domain: new URL(url).hostname,
          httpOnly: true,
          secure: url.startsWith("https"),
          version: "1",
        });
      } catch {}
    }
    appGroup.set("frigate_token", token);
    set({ token, username });
  },

  setBaseUrl: async (url) => {
    await SecureStore.setItemAsync("frigate_base_url", url);
    appGroup.set("frigate_base_url", url);
    set({ baseUrl: url });
  },

  logout: async () => {
    await Promise.all([
      SecureStore.deleteItemAsync("frigate_token"),
      SecureStore.deleteItemAsync("frigate_username"),
    ]);
    appGroup.remove("frigate_token");
    // Clear the iOS URLSession cookie jar too. Without this, the WebView and
    // axios (which both share URLSession) will keep sending the old stale
    // frigate_token cookie on the next login, causing JWT bad_signature errors.
    try { await CookieManager.clearAll(true); } catch {}
    try { await CookieManager.clearAll(false); } catch {}
    set({ token: null, username: null });
  },
}));
