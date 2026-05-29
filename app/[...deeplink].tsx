import { useEffect } from "react";
import { View } from "react-native";
import { useRouter } from "expo-router";
import * as Linking from "expo-linking";
import { pendingDeeplink } from "@/stores/pendingDeeplink";

// Catches any apex:// URL that expo-router can't match to a file route.
// Stores the URL for browser.tsx to consume, then redirects to the browser screen.
export default function DeeplinkCatcher() {
  const router = useRouter();
  useEffect(() => {
    Linking.getInitialURL().then((url) => {
      if (url?.startsWith("apex://")) pendingDeeplink.set(url);
      router.replace("/browser");
    });
  }, []);
  return <View style={{ flex: 1, backgroundColor: "#000000" }} />;
}
