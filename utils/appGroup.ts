/**
 * Thin wrapper around the ApexAppGroup native module.
 * Writes values to the shared App Group UserDefaults so the
 * Notification Service Extension can read them (e.g. frigate_token
 * for authenticated image downloads).
 *
 * On non-iOS platforms or simulator builds where the native module
 * isn't present, calls are silently no-ops.
 */
import { NativeModules, Platform } from "react-native";

const mod = NativeModules.ApexAppGroup as
  | { setItem(key: string, value: string): void; removeItem(key: string): void }
  | undefined;

export const appGroup = {
  set(key: string, value: string) {
    if (Platform.OS === "ios") mod?.setItem?.(key, value);
  },
  remove(key: string) {
    if (Platform.OS === "ios") mod?.removeItem?.(key);
  },
};
