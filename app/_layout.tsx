import React, { useCallback, useEffect, useMemo, useState } from "react";
import { Stack, useRouter } from "expo-router";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { StatusBar } from "expo-status-bar";
import { View, Text, ScrollView } from "react-native";
import { WebView } from "react-native-webview";
import * as Linking from "expo-linking";
import { useAuth } from "@/hooks/useAuth";
import { pendingDeeplink } from "@/stores/pendingDeeplink";
import { useDoorbellCall, type ActiveCall } from "@/hooks/useDoorbellCall";
import { useAuthStore } from "@/stores/authStore";
import { buildWsUrl, buildWebRTCHtml } from "@/utils/doorbellStream";

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
  const router = useRouter();
  const { baseUrl, token } = useAuthStore();

  // Camera name set when a VoIP push arrives — mounts a hidden 1×1 WebView
  // that runs the full WebRTC handshake so go2rtc buffers the RTSP stream
  // before the user taps Accept. Cleared when they answer or decline.
  const [preWarmCamera, setPreWarmCamera] = useState<string | null>(null);

  const preWarmWsUrl = useMemo(
    () => (preWarmCamera ? buildWsUrl(baseUrl, token, preWarmCamera) : ""),
    [baseUrl, token, preWarmCamera],
  );
  const preWarmHtml = useMemo(
    () => (preWarmWsUrl ? buildWebRTCHtml(preWarmWsUrl) : ""),
    [preWarmWsUrl],
  );

  // Intercept apex:// URLs when app is already running (foreground case).
  useEffect(() => {
    const sub = Linking.addEventListener("url", ({ url }) => {
      if (url.startsWith("apex://")) pendingDeeplink.set(url);
    });
    return () => sub.remove();
  }, []);

  const handlePush = useCallback((camera: string) => {
    setPreWarmCamera(camera);
  }, []);

  const handleAnswer = useCallback((call: ActiveCall) => {
    setPreWarmCamera(null); // stop pre-warm — doorbell-call takes over
    router.push(`/doorbell-call?camera=${encodeURIComponent(call.cameraName)}`);
  }, [router]);

  const handleEndCall = useCallback((_uuid: string) => {
    setPreWarmCamera(null);
  }, []);

  useDoorbellCall({ onAnswer: handleAnswer, onEndCall: handleEndCall, onPush: handlePush });

  return (
    <SafeAreaProvider>
      <GestureHandlerRootView style={{ flex: 1, backgroundColor: "#000000" }}>
        <StatusBar style="light" />

        {/* Hidden 1×1 pre-warm WebView — starts WebRTC handshake when push
            arrives so go2rtc buffers the RTSP stream before user answers. */}
        {preWarmCamera && preWarmWsUrl ? (
          <View
            style={{
              position: "absolute",
              width: 1,
              height: 1,
              top: -10,
              left: -10,
              opacity: 0,
            }}
          >
            <WebView
              source={{ html: preWarmHtml, baseUrl }}
              style={{ width: 1, height: 1 }}
              allowsInlineMediaPlayback={true}
              mediaPlaybackRequiresUserAction={false}
              sharedCookiesEnabled={true}
              originWhitelist={["*"]}
            />
          </View>
        ) : null}

        <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: "#000000" } }}>
          <Stack.Screen name="index" />
          <Stack.Screen name="(auth)" />
          <Stack.Screen name="browser" />
          <Stack.Screen name="[...deeplink]" />
          <Stack.Screen
            name="doorbell-call"
            options={{
              presentation: "fullScreenModal",
              headerShown: false,
              gestureEnabled: false,
              contentStyle: { backgroundColor: "#000000" },
            }}
          />
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
