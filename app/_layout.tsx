import React from "react";
import { Stack } from "expo-router";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { StatusBar } from "expo-status-bar";
import { View, Text, ScrollView } from "react-native";
import { useAuth } from "@/hooks/useAuth";

class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { error: string | null }
> {
  constructor(props: { children: React.ReactNode }) {
    super(props);
    this.state = { error: null };
  }
  static getDerivedStateFromError(e: unknown) {
    return { error: String(e) };
  }
  render() {
    if (this.state.error) {
      return (
        <View style={{ flex: 1, backgroundColor: "#1a0000", padding: 24, justifyContent: "center" }}>
          <Text style={{ color: "#ff4444", fontSize: 16, fontWeight: "700", marginBottom: 12 }}>
            JS Crash Caught:
          </Text>
          <ScrollView>
            <Text style={{ color: "#ffaaaa", fontSize: 12, fontFamily: "Courier" }}>
              {this.state.error}
            </Text>
          </ScrollView>
        </View>
      );
    }
    return this.props.children;
  }
}

function AppContent() {
  useAuth();
  return (
    <SafeAreaProvider>
      <GestureHandlerRootView style={{ flex: 1, backgroundColor: "#000000" }}>
        <StatusBar style="light" />
        <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: "#000000" } }}>
          <Stack.Screen name="index" />
          <Stack.Screen name="(auth)" />
          <Stack.Screen name="browser" />
        </Stack>
      </GestureHandlerRootView>
    </SafeAreaProvider>
  );
}

export default function RootLayout() {
  return (
    <ErrorBoundary>
      <AppContent />
    </ErrorBoundary>
  );
}
