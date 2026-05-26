import { useEffect } from "react";
import { View, ActivityIndicator } from "react-native";
import { useRouter } from "expo-router";
import { useAuthStore } from "@/stores/authStore";

export default function Index() {
  const router = useRouter();
  const { token, isLoading, initialize } = useAuthStore();

  useEffect(() => {
    initialize();
  }, []);

  useEffect(() => {
    if (isLoading) return;
    if (token) {
      router.replace("/browser");
    } else {
      router.replace("/(auth)/login");
    }
  }, [token, isLoading]);

  return (
    <View style={{ flex: 1, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
      <ActivityIndicator color="#00d4ff" size="large" />
    </View>
  );
}
