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
    const [token, username, baseUrl] = await Promise.all([
      SecureStore.getItemAsync("frigate_token"),
      SecureStore.getItemAsync("frigate_username"),
      SecureStore.getItemAsync("frigate_base_url"),
    ]);
    set({
      token,
      username,
      baseUrl: baseUrl ?? "https://frigate.plexserver525.com",
      isLoading: false,
    });
  },

  setAuth: (token, username) => {
    SecureStore.setItemAsync("frigate_token", token);
    SecureStore.setItemAsync("frigate_username", username);
    set({ token, username });
  },

  setBaseUrl: (url) => {
    SecureStore.setItemAsync("frigate_base_url", url);
    set({ baseUrl: url });
  },

  logout: () => {
    SecureStore.deleteItemAsync("frigate_token");
    set({ token: null, username: null });
  },
}));
