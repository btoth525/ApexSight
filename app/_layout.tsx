import { useEffect } from "react";
import { Stack } from "expo-router";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { StatusBar } from "expo-status-bar";
import * as Notifications from "expo-notifications";
import { useAuth } from "@/hooks/useAuth";
import "../global.css";

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: true,
    shouldSetBadge: true,
  }),
});

async function setupNotificationCategories() {
  await Notifications.setNotificationCategoryAsync("FRIGATE_ALERT", [
    {
      identifier: "VIEW_CLIP",
      buttonTitle: "▶ View Clip",
      options: { opensAppToForeground: true },
    },
    {
      identifier: "MARK_REVIEWED",
      buttonTitle: "✓ Reviewed",
      options: { opensAppToForeground: false },
    },
  ]);

  await Notifications.setNotificationCategoryAsync("FRIGATE_LIVE", [
    {
      identifier: "VIEW_LIVE",
      buttonTitle: "📹 Go Live",
      options: { opensAppToForeground: true },
    },
    {
      identifier: "SILENCE_30",
      buttonTitle: "🔕 Silence 30m",
      options: { opensAppToForeground: false },
    },
  ]);

  await Notifications.setNotificationCategoryAsync("FRIGATE_GUARD", [
    {
      identifier: "VIEW_LIVE",
      buttonTitle: "📹 Go Live",
      options: { opensAppToForeground: true },
    },
    {
      identifier: "OPEN_HUB",
      buttonTitle: "🛡️ Guard Hub",
      options: { opensAppToForeground: true },
    },
  ]);
}

export default function RootLayout() {
  useAuth();

  useEffect(() => {
    setupNotificationCategories().catch(console.warn);
  }, []);

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <StatusBar style="light" />
      <Stack screenOptions={{ headerShown: false }}>
        <Stack.Screen name="(auth)" />
        <Stack.Screen name="(tabs)" />
      </Stack>
    </GestureHandlerRootView>
  );
}
