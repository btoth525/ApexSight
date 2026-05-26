import { create } from "zustand";
import * as SecureStore from "expo-secure-store";
import { NOTIF_DEFAULTS } from "@/utils/notifTemplate";

const STORAGE_KEY = "apex_settings_v2";

type SettingsState = {
  notificationsEnabled: boolean;
  allowedCameras: string[];
  allowedLabels: string[];
  notifTitle: string;
  notifBody: string;
  notifActionsEnabled: boolean;
  wsConnected: boolean;
  pushTokenRegistered: boolean;

  initialize: () => Promise<void>;
  setNotificationsEnabled: (v: boolean) => void;
  setAllowedCameras: (cameras: string[]) => void;
  setAllowedLabels: (labels: string[]) => void;
  setNotifTitle: (v: string) => void;
  setNotifBody: (v: string) => void;
  setNotifActionsEnabled: (v: boolean) => void;
  setWsConnected: (v: boolean) => void;
  setPushTokenRegistered: (v: boolean) => void;
};

function persist(state: SettingsState) {
  SecureStore.setItemAsync(
    STORAGE_KEY,
    JSON.stringify({
      notificationsEnabled: state.notificationsEnabled,
      allowedCameras: state.allowedCameras,
      allowedLabels: state.allowedLabels,
      notifTitle: state.notifTitle,
      notifBody: state.notifBody,
      notifActionsEnabled: state.notifActionsEnabled,
    })
  ).catch(() => {});
}

export const useSettingsStore = create<SettingsState>((set, get) => ({
  notificationsEnabled: true,
  allowedCameras: [],
  allowedLabels: [],
  notifTitle: NOTIF_DEFAULTS.title,
  notifBody: NOTIF_DEFAULTS.body,
  notifActionsEnabled: true,
  wsConnected: false,
  pushTokenRegistered: false,

  initialize: async () => {
    try {
      const raw = await SecureStore.getItemAsync(STORAGE_KEY);
      if (raw) {
        const saved = JSON.parse(raw);
        set({
          notificationsEnabled: saved.notificationsEnabled ?? true,
          allowedCameras: saved.allowedCameras ?? [],
          allowedLabels: saved.allowedLabels ?? [],
          notifTitle: saved.notifTitle ?? NOTIF_DEFAULTS.title,
          notifBody: saved.notifBody ?? NOTIF_DEFAULTS.body,
          notifActionsEnabled: saved.notifActionsEnabled ?? true,
        });
      }
    } catch {}
  },

  setNotificationsEnabled: (v) => { set({ notificationsEnabled: v }); persist(get()); },
  setAllowedCameras: (cameras) => { set({ allowedCameras: cameras }); persist(get()); },
  setAllowedLabels: (labels) => { set({ allowedLabels: labels }); persist(get()); },
  setNotifTitle: (v) => { set({ notifTitle: v }); persist(get()); },
  setNotifBody: (v) => { set({ notifBody: v }); persist(get()); },
  setNotifActionsEnabled: (v) => { set({ notifActionsEnabled: v }); persist(get()); },
  setWsConnected: (v) => set({ wsConnected: v }),
  setPushTokenRegistered: (v) => set({ pushTokenRegistered: v }),
}));
