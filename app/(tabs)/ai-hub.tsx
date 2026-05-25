import { View, Text } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

export default function AIHubScreen() {
  return (
    <SafeAreaView className="flex-1 bg-background">
      <View className="flex-1 items-center justify-center">
        <Text className="text-4xl mb-4">🛡️</Text>
        <Text className="text-text-primary text-xl font-semibold">AI Hub</Text>
        <Text className="text-text-secondary mt-2">Phase 5 — coming soon</Text>
      </View>
    </SafeAreaView>
  );
}
