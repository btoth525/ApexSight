import { create } from "zustand";
import * as SecureStore from "expo-secure-store";

type AuthState = {
  token: string | null;
  username: string | null;
  baseUrl: string;
  isLoading: boolean;
  setAuth: (token: string, username: string) => void;
  setBaseUrl: (url: string) => void;
  logout: () => void;
  initialize: () => Promise<void>;
};

export const useAuthStore = create<AuthState>((set) => ({
  token: null,
  username: null,
  baseUrl: "https://frigate.plexserver525.com",
  isLoading: true,

  initialize: async () => {
    const [username, baseUrl] = await Promise.all([
      SecureStore.getItemAsync("frigate_username"),
      SecureStore.getItemAsync("frigate_base_url"),
    ]);
    // token is used only as a truthy "logged in" flag; iOS holds the real cookie.
    set({
      token: username ? "session" : null,
      username,
      baseUrl: baseUrl ?? "https://frigate.plexserver525.com",
      isLoading: false,
    });
  },

  setAuth: (_token, username) => {
    SecureStore.setItemAsync("frigate_username", username);
    set({ token: "session", username });
  },

  setBaseUrl: (url) => {
    SecureStore.setItemAsync("frigate_base_url", url);
    set({ baseUrl: url });
  },

  logout: () => {
    SecureStore.deleteItemAsync("frigate_username");
    set({ token: null, username: null });
  },
}));
