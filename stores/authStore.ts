import { create } from "zustand";
import * as SecureStore from "expo-secure-store";
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

export const useAuthStore = create<AuthState>((set) => ({
  token: null,
  username: null,
  baseUrl: "https://frigate.plexserver525.com",
  isLoading: true,

  initialize: async () => {
    const [token, username, baseUrl] = await Promise.all([
      SecureStore.getItemAsync("frigate_token"),
      SecureStore.getItemAsync("frigate_username"),
      SecureStore.getItemAsync("frigate_base_url"),
    ]);
    if (token) appGroup.set("frigate_token", token);
    if (baseUrl) appGroup.set("frigate_base_url", baseUrl);
    set({
      token,
      username,
      baseUrl: baseUrl ?? "https://frigate.plexserver525.com",
      isLoading: false,
    });
  },

  setAuth: async (token, username) => {
    await Promise.all([
      SecureStore.setItemAsync("frigate_token", token),
      SecureStore.setItemAsync("frigate_username", username),
    ]);
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
    set({ token: null, username: null });
  },
}));
