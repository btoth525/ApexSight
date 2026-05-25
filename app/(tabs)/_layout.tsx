import { Tabs } from "expo-router";
import { View } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { OfflineBanner } from "@/components/ui/OfflineBanner";
import { useAlertNotifications } from "@/hooks/useAlertNotifications";

type IconProps = { name: React.ComponentProps<typeof Ionicons>["name"]; focused: boolean };

function TabIcon({ name, focused }: IconProps) {
  return (
    <View style={{ alignItems: "center", justifyContent: "center", paddingTop: 4 }}>
      <Ionicons name={name} size={24} color={focused ? "#00d4ff" : "#475569"} />
      {focused && (
        <View style={{ width: 4, height: 4, borderRadius: 2, backgroundColor: "#00d4ff", marginTop: 3 }} />
      )}
    </View>
  );
}

export default function TabsLayout() {
  // Listen for alert events and trigger rich iOS notifications with snapshots
  useAlertNotifications();

  return (
    <View style={{ flex: 1 }}>
      <OfflineBanner />
      <Tabs
        screenOptions={{
          headerShown: false,
          tabBarStyle: {
            backgroundColor: "#0a0f1e",
            borderTopColor: "#1e293b",
            borderTopWidth: 1,
            height: 64,
            paddingBottom: 8,
          },
          tabBarShowLabel: false,
        }}
      >
        <Tabs.Screen name="index"    options={{ tabBarIcon: ({ focused }) => <TabIcon name={focused ? "videocam" : "videocam-outline"} focused={focused} /> }} />
        <Tabs.Screen name="review"   options={{ tabBarIcon: ({ focused }) => <TabIcon name={focused ? "notifications" : "notifications-outline"} focused={focused} /> }} />
        <Tabs.Screen name="explore"  options={{ tabBarIcon: ({ focused }) => <TabIcon name={focused ? "search" : "search-outline"} focused={focused} /> }} />
        <Tabs.Screen name="ai-hub"   options={{ tabBarIcon: ({ focused }) => <TabIcon name={focused ? "shield" : "shield-outline"} focused={focused} /> }} />
        <Tabs.Screen name="settings" options={{ tabBarIcon: ({ focused }) => <TabIcon name={focused ? "settings" : "settings-outline"} focused={focused} /> }} />
      </Tabs>
    </View>
  );
}
