import { useRef, useState, useCallback, useEffect } from "react";
import {
  View, Text, TouchableOpacity, ActivityIndicator,
  Alert, Switch, Modal,
} from "react-native";
import { WebView, WebViewNavigation } from "react-native-webview";
import { SafeAreaView, useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import CookieManager from "@react-native-cookies/cookies";
import { useRouter } from "expo-router";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";
import { useAlertNotifications } from "@/hooks/useAlertNotifications";
import { useExpoPushRegistration } from "@/hooks/useExpoPushRegistration";
import { haptic } from "@/utils/haptics";
import * as Notifications from "expo-notifications";

export default function BrowserScreen() {
  const { baseUrl, token, logout } = useAuthStore();
  const { notificationsEnabled, setNotificationsEnabled } = useSettingsStore();
  const router = useRouter();
  const webviewRef = useRef<WebView>(null);
  const insets = useSafeAreaInsets();
  const [cookieReady, setCookieReady] = useState(false);
  const [loading, setLoading] = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Run the native notification service (works when app is open)
  useAlertNotifications();
  // Register Expo Push token for true background notifications (app killed)
  useExpoPushRegistration();

  // Inject auth cookie before WebView loads
  useEffect(() => {
    const inject = async () => {
      if (token && token !== "session" && baseUrl) {
        try {
          const { hostname, protocol } = new URL(baseUrl);
          await CookieManager.set(baseUrl, {
            name: "frigate_token",
            value: token,
            domain: hostname,
            path: "/",
            secure: protocol === "https:",
            httpOnly: false,
            version: "1",
          });
        } catch {}
      }
      setCookieReady(true);
    };
    inject();
  }, [baseUrl, token]);

  const handleNavChange = useCallback((nav: WebViewNavigation) => {
    // Frigate redirected to login — token expired
    if (nav.url.includes("/login") && nav.url !== `${baseUrl}/login`) {
      logout();
    }
  }, [baseUrl, logout]);

  const handleLogout = () => {
    haptic.medium();
    Alert.alert("Sign Out", "Are you sure?", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Sign Out", style: "destructive",
        onPress: () => {
          haptic.success();
          setSettingsOpen(false);
          logout();
          router.replace("/(auth)/login");
        },
      },
    ]);
  };

  const handleToggleNotifications = async (value: boolean) => {
    if (value) {
      const { status } = await Notifications.requestPermissionsAsync();
      if (status !== "granted") {
        haptic.error();
        Alert.alert("Permission Required", "Enable notifications in Settings → Apex Sight.");
        return;
      }
    }
    haptic.medium();
    setNotificationsEnabled(value);
  };

  if (!cookieReady) {
    return (
      <View style={{ flex: 1, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
        <ActivityIndicator color="#00d4ff" size="large" />
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: "#000" }}>
      {/* Respect safe areas so Frigate PWA content isn't hidden behind status bar or home indicator */}
      <View style={{ flex: 1, paddingTop: insets.top, paddingBottom: insets.bottom, backgroundColor: "#000" }}>
        <WebView
          ref={webviewRef}
          source={{ uri: baseUrl }}
          style={{ flex: 1 }}
          sharedCookiesEnabled={true}
          allowsBackForwardNavigationGestures={true}
          pullToRefreshEnabled={true}
          allowsInlineMediaPlayback={true}
          mediaPlaybackRequiresUserAction={false}
          allowsFullscreenVideo={true}
          onNavigationStateChange={handleNavChange}
          onLoadStart={() => setLoading(true)}
          onLoadEnd={() => setLoading(false)}
        />
      </View>

      {/* Loading overlay — covers full screen including safe areas */}
      {loading && (
        <View style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
          <View style={{ width: 56, height: 56, borderRadius: 16, backgroundColor: "#1e293b", alignItems: "center", justifyContent: "center", marginBottom: 14 }}>
            <Ionicons name="shield" size={28} color="#00d4ff" />
          </View>
          <ActivityIndicator color="#00d4ff" />
          <Text style={{ color: "#64748b", marginTop: 10, fontSize: 13 }}>Connecting to Frigate…</Text>
        </View>
      )}

      {/* Floating settings button — bottom-right above home indicator, avoids Frigate's top UI */}
      <TouchableOpacity
        onPress={() => { haptic.tap(); setSettingsOpen(true); }}
        style={{
          position: "absolute",
          bottom: insets.bottom + 80,
          right: 14,
          width: 34,
          height: 34,
          borderRadius: 10,
          backgroundColor: "#0a0f1ecc",
          borderWidth: 1,
          borderColor: "#1e293b",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <Ionicons name="ellipsis-horizontal" size={16} color="#94a3b8" />
      </TouchableOpacity>

      {/* Settings modal */}
      <Modal
        visible={settingsOpen}
        transparent
        animationType="slide"
        onRequestClose={() => setSettingsOpen(false)}
      >
        <TouchableOpacity
          style={{ flex: 1, backgroundColor: "#00000088" }}
          activeOpacity={1}
          onPress={() => setSettingsOpen(false)}
        />
        <SafeAreaView style={{ backgroundColor: "#0f172a" }} edges={["bottom"]}>
          <View style={{ backgroundColor: "#0f172a", borderTopLeftRadius: 20, borderTopRightRadius: 20, borderTopWidth: 1, borderColor: "#1e293b", padding: 20, gap: 14 }}>

            {/* Handle */}
            <View style={{ width: 36, height: 4, borderRadius: 2, backgroundColor: "#334155", alignSelf: "center", marginBottom: 4 }} />

            {/* Header */}
            <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
              <Ionicons name="shield" size={18} color="#00d4ff" />
              <Text style={{ color: "#f1f5f9", fontSize: 17, fontWeight: "700" }}>Apex Sight</Text>
            </View>

            {/* Server */}
            <View style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, gap: 4 }}>
              <Text style={{ color: "#475569", fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.8 }}>Connected Server</Text>
              <Text style={{ color: "#94a3b8", fontSize: 13 }} numberOfLines={1}>{baseUrl}</Text>
            </View>

            {/* Notifications toggle */}
            <View style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, flexDirection: "row", alignItems: "center", justifyContent: "space-between" }}>
              <View style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
                <View style={{ width: 32, height: 32, borderRadius: 8, backgroundColor: "#00d4ff22", alignItems: "center", justifyContent: "center" }}>
                  <Ionicons name="notifications" size={16} color="#00d4ff" />
                </View>
                <View>
                  <Text style={{ color: "#f1f5f9", fontSize: 15, fontWeight: "500" }}>Push Alerts</Text>
                  <Text style={{ color: "#64748b", fontSize: 12 }}>Rich notifications with snapshots</Text>
                </View>
              </View>
              <Switch
                value={notificationsEnabled}
                onValueChange={handleToggleNotifications}
                trackColor={{ false: "#334155", true: "#00d4ff" }}
                thumbColor="#fff"
                ios_backgroundColor="#334155"
              />
            </View>

            {/* Reload */}
            <TouchableOpacity
              onPress={() => { haptic.tap(); webviewRef.current?.reload(); setSettingsOpen(false); }}
              style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, flexDirection: "row", alignItems: "center", gap: 10 }}
            >
              <View style={{ width: 32, height: 32, borderRadius: 8, backgroundColor: "#a855f722", alignItems: "center", justifyContent: "center" }}>
                <Ionicons name="refresh" size={16} color="#a855f7" />
              </View>
              <Text style={{ color: "#f1f5f9", fontSize: 15, fontWeight: "500" }}>Reload</Text>
            </TouchableOpacity>

            {/* Sign out */}
            <TouchableOpacity
              onPress={handleLogout}
              style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, flexDirection: "row", alignItems: "center", gap: 10 }}
            >
              <View style={{ width: 32, height: 32, borderRadius: 8, backgroundColor: "#ef444422", alignItems: "center", justifyContent: "center" }}>
                <Ionicons name="log-out" size={16} color="#ef4444" />
              </View>
              <Text style={{ color: "#ef4444", fontSize: 15, fontWeight: "500" }}>Sign Out</Text>
            </TouchableOpacity>

          </View>
        </SafeAreaView>
      </Modal>
    </View>
  );
}
