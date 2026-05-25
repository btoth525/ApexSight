import { create } from "zustand";
import * as SecureStore from "expo-secure-store";

type SettingsState = {
  notificationsEnabled: boolean;
  cameraOrder: string[];
  cameraDisplayNames: Record<string, string>;
  setNotificationsEnabled: (v: boolean) => void;
  setCameraOrder: (order: string[]) => void;
  setCameraDisplayName: (camera: string, name: string) => void;
};

export const useSettingsStore = create<SettingsState>((set) => ({
  notificationsEnabled: true,
  cameraOrder: [],
  cameraDisplayNames: {},

  setNotificationsEnabled: (v) => set({ notificationsEnabled: v }),
  setCameraOrder: (order) => set({ cameraOrder: order }),
  setCameraDisplayName: (camera, name) =>
    set((s) => ({
      cameraDisplayNames: { ...s.cameraDisplayNames, [camera]: name },
    })),
}));
