import { Tabs } from "expo-router";
import { View, Text } from "react-native";

function TabIcon({ emoji, label, focused }: { emoji: string; label: string; focused: boolean }) {
  return (
    <View className="items-center">
      <Text className="text-xl">{emoji}</Text>
      <Text className={`text-xs mt-0.5 ${focused ? "text-primary" : "text-text-secondary"}`}>
        {label}
      </Text>
    </View>
  );
}

export default function TabsLayout() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarStyle: {
          backgroundColor: "#0f172a",
          borderTopColor: "#334155",
          borderTopWidth: 1,
          paddingBottom: 4,
          height: 60,
        },
        tabBarShowLabel: false,
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          tabBarIcon: ({ focused }) => (
            <TabIcon emoji="📹" label="Live" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="review"
        options={{
          tabBarIcon: ({ focused }) => (
            <TabIcon emoji="🔔" label="Review" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="explore"
        options={{
          tabBarIcon: ({ focused }) => (
            <TabIcon emoji="🔍" label="Explore" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="ai-hub"
        options={{
          tabBarIcon: ({ focused }) => (
            <TabIcon emoji="🛡️" label="AI Hub" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          tabBarIcon: ({ focused }) => (
            <TabIcon emoji="⚙️" label="Settings" focused={focused} />
          ),
        }}
      />
    </Tabs>
  );
}
