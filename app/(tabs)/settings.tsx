import { View, Text, TouchableOpacity } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useAuthStore } from "@/stores/authStore";
import { useRouter } from "expo-router";

export default function SettingsScreen() {
  const { logout, username, baseUrl } = useAuthStore();
  const router = useRouter();

  const handleLogout = () => {
    logout();
    router.replace("/(auth)/login");
  };

  return (
    <SafeAreaView className="flex-1 bg-background">
      <View className="flex-1 px-4 py-6">
        <Text className="text-text-primary text-2xl font-bold mb-6">Settings</Text>

        <View className="bg-surface rounded-xl p-4 mb-4">
          <Text className="text-text-secondary text-sm mb-1">Signed in as</Text>
          <Text className="text-text-primary font-semibold">{username ?? "Unknown"}</Text>
          <Text className="text-text-secondary text-sm mt-1">{baseUrl}</Text>
        </View>

        <TouchableOpacity
          className="bg-danger rounded-xl py-4 items-center mt-auto"
          onPress={handleLogout}
        >
          <Text className="text-white font-semibold">Sign Out</Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}
