import { create } from "zustand";
import * as SecureStore from "expo-secure-store";

const STORAGE_KEY = "apex_settings_v1";

type SettingsState = {
  notificationsEnabled: boolean;
  allowedCameras: string[];    // empty = all cameras
  allowedLabels: string[];     // empty = all labels
  faceIdEnabled: boolean;
  wsConnected: boolean;
  pushTokenRegistered: boolean;

  initialize: () => Promise<void>;
  setNotificationsEnabled: (v: boolean) => void;
  setAllowedCameras: (cameras: string[]) => void;
  setAllowedLabels: (labels: string[]) => void;
  setFaceIdEnabled: (v: boolean) => void;
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
      faceIdEnabled: state.faceIdEnabled,
    })
  ).catch(() => {});
}

export const useSettingsStore = create<SettingsState>((set, get) => ({
  notificationsEnabled: true,
  allowedCameras: [],
  allowedLabels: [],
  faceIdEnabled: true,
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
          faceIdEnabled: saved.faceIdEnabled ?? true,
        });
      }
    } catch {}
  },

  setNotificationsEnabled: (v) => { set({ notificationsEnabled: v }); persist(get()); },
  setAllowedCameras: (cameras) => { set({ allowedCameras: cameras }); persist(get()); },
  setAllowedLabels: (labels) => { set({ allowedLabels: labels }); persist(get()); },
  setFaceIdEnabled: (v) => { set({ faceIdEnabled: v }); persist(get()); },
  setWsConnected: (v) => set({ wsConnected: v }),
  setPushTokenRegistered: (v) => set({ pushTokenRegistered: v }),
}));
