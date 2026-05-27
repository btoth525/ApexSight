import { create } from "zustand";

// Lightweight runtime-only store. Notification settings were removed —
// push automation is now handled by Home Assistant via apex:// deep links.
type SettingsState = {
  wsConnected: boolean;
  setWsConnected: (v: boolean) => void;
};

export const useSettingsStore = create<SettingsState>((set) => ({
  wsConnected: false,
  setWsConnected: (v) => set({ wsConnected: v }),
}));
