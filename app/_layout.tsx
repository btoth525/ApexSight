import React, { useEffect } from "react";
import { Stack } from "expo-router";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { StatusBar } from "expo-status-bar";
import { View, Text, ScrollView } from "react-native";
import * as Linking from "expo-linking";
import { useAuth } from "@/hooks/useAuth";
import { pendingDeeplink } from "@/stores/pendingDeeplink";
import { AppleMaterial, apple } from "@/components/AppleMaterial";

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
        <View style={{ flex: 1, backgroundColor: apple.colors.background, padding: 24, justifyContent: "center" }}>
          <AppleMaterial tint="systemMaterialDark" intensity={88} contentStyle={{ padding: 22, gap: 12 }}>
            <Text style={{ color: apple.colors.label, fontSize: 22, fontWeight: "800" }}>
              Apex needs a refresh
            </Text>
            <Text style={{ color: apple.colors.secondaryLabel, fontSize: 14, lineHeight: 20 }}>
              Something unexpected happened while opening the app.
            </Text>
            <ScrollView style={{ maxHeight: 160 }}>
              <Text style={{ color: apple.colors.tertiaryLabel, fontSize: 12, fontFamily: "Courier" }}>
                {this.state.error}
              </Text>
            </ScrollView>
          </AppleMaterial>
        </View>
      );
    }
    return this.props.children;
  }
}

function AppContent() {
  useAuth();

  useEffect(() => {
    const sub = Linking.addEventListener("url", ({ url }) => {
      if (url.startsWith("apex://")) pendingDeeplink.set(url);
    });
    return () => sub.remove();
  }, []);

  return (
    <SafeAreaProvider>
      <GestureHandlerRootView style={{ flex: 1, backgroundColor: "#000000" }}>
        <StatusBar style="light" />
        <Stack
          screenOptions={{
            headerShown: false,
            animation: "slide_from_right",
            contentStyle: { backgroundColor: apple.colors.background },
            fullScreenGestureEnabled: true,
          }}
        >
          <Stack.Screen name="index" />
          <Stack.Screen name="(auth)" />
          <Stack.Screen name="native" />
          <Stack.Screen name="event/[id]" />
          <Stack.Screen name="system" />
          <Stack.Screen name="browser" />
          <Stack.Screen name="[...deeplink]" />
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
