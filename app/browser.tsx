import { useRef, useState, useCallback, useEffect } from "react";
import {
  View, Text, TouchableOpacity, ActivityIndicator,
  Alert, Switch, Modal, ScrollView, TextInput,
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
import { apiClient } from "@/utils/apiClient";

// Common Frigate object labels with emojis
const KNOWN_LABELS: { id: string; emoji: string; name: string }[] = [
  { id: "person",       emoji: "🚶", name: "Person"    },
  { id: "car",          emoji: "🚗", name: "Car"       },
  { id: "dog",          emoji: "🐕", name: "Dog"       },
  { id: "cat",          emoji: "🐈", name: "Cat"       },
  { id: "package",      emoji: "📦", name: "Package"   },
  { id: "bicycle",      emoji: "🚲", name: "Bicycle"   },
  { id: "motorcycle",   emoji: "🏍️", name: "Motorcycle"},
  { id: "bird",         emoji: "🐦", name: "Bird"      },
  { id: "bear",         emoji: "🐻", name: "Bear"      },
  { id: "fire",         emoji: "🔥", name: "Fire"      },
];

function Row({
  icon, iconColor, iconBg, label, sub, right,
}: {
  icon: string; iconColor: string; iconBg: string;
  label: string; sub?: string; right?: React.ReactNode;
}) {
  return (
    <View style={{ flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 4 }}>
      <View style={{ width: 34, height: 34, borderRadius: 8, backgroundColor: iconBg, alignItems: "center", justifyContent: "center" }}>
        <Ionicons name={icon as any} size={17} color={iconColor} />
      </View>
      <View style={{ flex: 1 }}>
        <Text style={{ color: "#f1f5f9", fontSize: 15, fontWeight: "500" }}>{label}</Text>
        {sub ? <Text style={{ color: "#64748b", fontSize: 12, marginTop: 1 }}>{sub}</Text> : null}
      </View>
      {right}
    </View>
  );
}

function SectionHeader({ title }: { title: string }) {
  return (
    <Text style={{ color: "#475569", fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.8, marginTop: 8, marginBottom: 4 }}>
      {title}
    </Text>
  );
}

export default function BrowserScreen() {
  const { baseUrl, token, setBaseUrl, logout } = useAuthStore();
  const {
    notificationsEnabled, setNotificationsEnabled,
    allowedCameras, setAllowedCameras,
    allowedLabels, setAllowedLabels,
    wsConnected, pushTokenRegistered,
  } = useSettingsStore();

  const router = useRouter();
  const webviewRef = useRef<WebView>(null);
  const insets = useSafeAreaInsets();

  const [cookieReady, setCookieReady] = useState(false);
  const [loading, setLoading] = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Server editing
  const [editingUrl, setEditingUrl] = useState(false);
  const [urlDraft, setUrlDraft] = useState(baseUrl);

  // Camera list for filter (fetched from Frigate when settings open)
  const [availCameras, setAvailCameras] = useState<string[]>([]);

  useAlertNotifications();
  const { retryRegister } = useExpoPushRegistration();

  // Deep-link: tapping a push notification navigates WebView to that review
  useEffect(() => {
    // App already open — user tapped a notification banner
    const sub = Notifications.addNotificationResponseReceivedListener((response) => {
      const data = response.notification.request.content.data as Record<string, string> | undefined;
      const reviewId = data?.review_id;
      const camera   = data?.camera;
      const url = reviewId
        ? `${baseUrl}/review?id=${reviewId}`
        : camera
        ? `${baseUrl}/review?cameras=${camera}`
        : `${baseUrl}/review`;
      webviewRef.current?.injectJavaScript(`window.location.href = ${JSON.stringify(url)}; true;`);
      setSettingsOpen(false);
    });

    // App was killed — launched from notification tap
    Notifications.getLastNotificationResponseAsync().then((response) => {
      if (!response) return;
      const data = response.notification.request.content.data as Record<string, string> | undefined;
      const reviewId = data?.review_id;
      const camera   = data?.camera;
      const url = reviewId
        ? `${baseUrl}/review?id=${reviewId}`
        : camera
        ? `${baseUrl}/review?cameras=${camera}`
        : `${baseUrl}/review`;
      // Wait for WebView to finish its initial load before navigating
      setTimeout(() => {
        webviewRef.current?.injectJavaScript(`window.location.href = ${JSON.stringify(url)}; true;`);
      }, 1500);
    });

    return () => sub.remove();
  }, [baseUrl]);

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

  // Fetch camera list when settings open
  useEffect(() => {
    if (!settingsOpen) return;
    apiClient.get("/config").then((res) => {
      const cameras = Object.keys(res.data?.cameras ?? {});
      if (cameras.length > 0) setAvailCameras(cameras);
    }).catch(() => {});
  }, [settingsOpen]);

  const prevUrlRef = useRef<string | null>(null);
  const handleNavChange = useCallback((nav: WebViewNavigation) => {
    // Track current URL — used for deep-link navigation only.
    // We deliberately do NOT auto-logout when the WebView hits /login
    // because Frigate's PWA can hit that URL during normal flow, and any
    // false positive there would kick the user out of the app entirely.
    // If the user wants to sign out they can do it from settings.
    prevUrlRef.current = nav.url;
  }, []);

  const handleSaveUrl = async () => {
    const clean = urlDraft.trim().replace(/\/$/, "");
    if (!clean) return;
    await setBaseUrl(clean);
    setEditingUrl(false);
    setTimeout(() => webviewRef.current?.reload(), 300);
  };

  const handleToggleNotifications = async (value: boolean) => {
    if (value) {
      const { status } = await Notifications.requestPermissionsAsync();
      if (status !== "granted") {
        haptic.error();
        Alert.alert("Permission Required", "Enable notifications in Settings → Apex.");
        return;
      }
    }
    haptic.medium();
    setNotificationsEnabled(value);
  };

  const handleToggleCamera = (camera: string) => {
    haptic.tap();
    const next = allowedCameras.includes(camera)
      ? allowedCameras.filter((c) => c !== camera)
      : [...allowedCameras, camera];
    setAllowedCameras(next);
  };

  const handleToggleLabel = (label: string) => {
    haptic.tap();
    const next = allowedLabels.includes(label)
      ? allowedLabels.filter((l) => l !== label)
      : [...allowedLabels, label];
    setAllowedLabels(next);
  };

  const handleTestNotification = async () => {
    haptic.success();
    await Notifications.scheduleNotificationAsync({
      content: {
        title: "🛡️ Apex",
        body: "Notifications are working!",
        sound: "default",
      },
      trigger: null,
    });
  };

  const handleLogout = () => {
    haptic.medium();
    Alert.alert("Sign Out", "Are you sure?", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Sign Out", style: "destructive",
        onPress: async () => {
          haptic.success();
          setSettingsOpen(false);
          await logout();
          router.replace("/(auth)/login");
        },
      },
    ]);
  };

  if (!cookieReady) {
    return (
      <View style={{ flex: 1, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
        <ActivityIndicator color="#00d4ff" size="large" />
      </View>
    );
  }

  const cameraFilterSub = allowedCameras.length === 0
    ? "All cameras"
    : allowedCameras.map((c) => c.replace(/_/g, " ")).join(", ");

  const labelFilterSub = allowedLabels.length === 0
    ? "All labels"
    : allowedLabels.map((l) => KNOWN_LABELS.find((k) => k.id === l)?.name ?? l).join(", ");

  return (
    <View style={{ flex: 1, backgroundColor: "#000" }}>
      {/* Safe-area inset so Frigate PWA content clears status bar and home indicator */}
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

      {/* Loading overlay — full screen */}
      {loading && (
        <View style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
          <View style={{ width: 56, height: 56, borderRadius: 16, backgroundColor: "#1e293b", alignItems: "center", justifyContent: "center", marginBottom: 14 }}>
            <Ionicons name="shield" size={28} color="#00d4ff" />
          </View>
          <ActivityIndicator color="#00d4ff" />
          <Text style={{ color: "#64748b", marginTop: 10, fontSize: 13 }}>Connecting to Frigate…</Text>
        </View>
      )}

      {/* Floating settings button — bottom-right, above Frigate nav bar */}
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

      {/* ── Settings modal ─────────────────────────────────────────────────── */}
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
          <View style={{ backgroundColor: "#0f172a", borderTopLeftRadius: 20, borderTopRightRadius: 20, borderTopWidth: 1, borderColor: "#1e293b", maxHeight: "82%" }}>

            {/* Handle + header */}
            <View style={{ padding: 20, paddingBottom: 0 }}>
              <View style={{ width: 36, height: 4, borderRadius: 2, backgroundColor: "#334155", alignSelf: "center", marginBottom: 16 }} />
              <View style={{ flexDirection: "row", alignItems: "center", gap: 8, marginBottom: 4 }}>
                <Ionicons name="shield" size={18} color="#00d4ff" />
                <Text style={{ color: "#f1f5f9", fontSize: 17, fontWeight: "700" }}>Apex Settings</Text>
              </View>
            </View>

            <ScrollView
              style={{ paddingHorizontal: 20 }}
              contentContainerStyle={{ paddingBottom: 20, gap: 0 }}
              showsVerticalScrollIndicator={false}
            >

              {/* ── SERVER ─────────────────────────────────────── */}
              <SectionHeader title="Server" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, gap: 10 }}>
                {editingUrl ? (
                  <>
                    <TextInput
                      style={{ color: "#f1f5f9", fontSize: 14, backgroundColor: "#0f172a", borderRadius: 8, padding: 10, borderWidth: 1, borderColor: "#334155" }}
                      value={urlDraft}
                      onChangeText={setUrlDraft}
                      autoCapitalize="none"
                      autoCorrect={false}
                      keyboardType="url"
                      placeholder="https://your-frigate-host.com"
                      placeholderTextColor="#475569"
                    />
                    <View style={{ flexDirection: "row", gap: 8 }}>
                      <TouchableOpacity onPress={() => setEditingUrl(false)} style={{ flex: 1, backgroundColor: "#334155", borderRadius: 8, paddingVertical: 10, alignItems: "center" }}>
                        <Text style={{ color: "#94a3b8", fontWeight: "600" }}>Cancel</Text>
                      </TouchableOpacity>
                      <TouchableOpacity onPress={handleSaveUrl} style={{ flex: 1, backgroundColor: "#00d4ff", borderRadius: 8, paddingVertical: 10, alignItems: "center" }}>
                        <Text style={{ color: "#0a0f1e", fontWeight: "700" }}>Save & Reload</Text>
                      </TouchableOpacity>
                    </View>
                  </>
                ) : (
                  <Row
                    icon="globe-outline" iconColor="#00d4ff" iconBg="#00d4ff22"
                    label={baseUrl.replace("https://", "")}
                    sub="Tap to change server URL"
                    right={
                      <TouchableOpacity onPress={() => { setUrlDraft(baseUrl); setEditingUrl(true); }}>
                        <Ionicons name="pencil-outline" size={18} color="#475569" />
                      </TouchableOpacity>
                    }
                  />
                )}
              </View>

              {/* ── NOTIFICATIONS ─────────────────────────────── */}
              <SectionHeader title="Notifications" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, gap: 14 }}>

                {/* Master toggle */}
                <Row
                  icon="notifications" iconColor="#00d4ff" iconBg="#00d4ff22"
                  label="Push Alerts"
                  sub="Rich notifications with snapshots"
                  right={
                    <Switch
                      value={notificationsEnabled}
                      onValueChange={handleToggleNotifications}
                      trackColor={{ false: "#334155", true: "#00d4ff" }}
                      thumbColor="#fff"
                      ios_backgroundColor="#334155"
                    />
                  }
                />

                {notificationsEnabled && (
                  <>
                    <View style={{ height: 1, backgroundColor: "#334155" }} />

                    {/* Camera filter */}
                    <View>
                      <Row
                        icon="videocam-outline" iconColor="#a855f7" iconBg="#a855f722"
                        label="Camera Filter"
                        sub={cameraFilterSub}
                      />
                      {availCameras.length > 0 && (
                        <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8, marginTop: 10 }}>
                          {availCameras.map((cam) => {
                            const on = allowedCameras.length === 0 || allowedCameras.includes(cam);
                            const selected = allowedCameras.includes(cam);
                            return (
                              <TouchableOpacity
                                key={cam}
                                onPress={() => handleToggleCamera(cam)}
                                style={{
                                  paddingHorizontal: 12, paddingVertical: 6,
                                  borderRadius: 8, borderWidth: 1,
                                  backgroundColor: selected ? "#a855f722" : "transparent",
                                  borderColor: selected ? "#a855f7" : "#334155",
                                }}
                              >
                                <Text style={{ color: selected ? "#a855f7" : "#64748b", fontSize: 13, fontWeight: "500" }}>
                                  {cam.replace(/_/g, " ")}
                                </Text>
                              </TouchableOpacity>
                            );
                          })}
                          {allowedCameras.length > 0 && (
                            <TouchableOpacity
                              onPress={() => { haptic.tap(); setAllowedCameras([]); }}
                              style={{ paddingHorizontal: 12, paddingVertical: 6, borderRadius: 8, borderWidth: 1, borderColor: "#ef4444" }}
                            >
                              <Text style={{ color: "#ef4444", fontSize: 13, fontWeight: "500" }}>Clear (all)</Text>
                            </TouchableOpacity>
                          )}
                        </View>
                      )}
                    </View>

                    <View style={{ height: 1, backgroundColor: "#334155" }} />

                    {/* Label filter */}
                    <View>
                      <Row
                        icon="pricetag-outline" iconColor="#f59e0b" iconBg="#f59e0b22"
                        label="Object Filter"
                        sub={labelFilterSub}
                      />
                      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8, marginTop: 10 }}>
                        {KNOWN_LABELS.map(({ id, emoji, name }) => {
                          const selected = allowedLabels.includes(id);
                          return (
                            <TouchableOpacity
                              key={id}
                              onPress={() => handleToggleLabel(id)}
                              style={{
                                paddingHorizontal: 12, paddingVertical: 6,
                                borderRadius: 8, borderWidth: 1,
                                backgroundColor: selected ? "#f59e0b22" : "transparent",
                                borderColor: selected ? "#f59e0b" : "#334155",
                              }}
                            >
                              <Text style={{ color: selected ? "#f59e0b" : "#64748b", fontSize: 13, fontWeight: "500" }}>
                                {emoji} {name}
                              </Text>
                            </TouchableOpacity>
                          );
                        })}
                        {allowedLabels.length > 0 && (
                          <TouchableOpacity
                            onPress={() => { haptic.tap(); setAllowedLabels([]); }}
                            style={{ paddingHorizontal: 12, paddingVertical: 6, borderRadius: 8, borderWidth: 1, borderColor: "#ef4444" }}
                          >
                            <Text style={{ color: "#ef4444", fontSize: 13, fontWeight: "500" }}>Clear (all)</Text>
                          </TouchableOpacity>
                        )}
                      </View>
                    </View>
                  </>
                )}
              </View>

              {/* ── STATUS ────────────────────────────────────── */}
              <SectionHeader title="Status" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, gap: 14 }}>
                <Row
                  icon={wsConnected ? "wifi" : "wifi-outline"}
                  iconColor={wsConnected ? "#10b981" : "#ef4444"}
                  iconBg={wsConnected ? "#10b98122" : "#ef444422"}
                  label="Live Events"
                  sub={wsConnected ? "WebSocket connected" : "WebSocket disconnected"}
                />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <Row
                  icon={pushTokenRegistered ? "cloud-done-outline" : "cloud-offline-outline"}
                  iconColor={pushTokenRegistered ? "#10b981" : "#f59e0b"}
                  iconBg={pushTokenRegistered ? "#10b98122" : "#f59e0b22"}
                  label="Background Push"
                  sub={
                    pushTokenRegistered
                      ? "Token registered with Frigate"
                      : "Not registered — background alerts won't work"
                  }
                />
              </View>

              {/* ── ACTIONS ───────────────────────────────────── */}
              <SectionHeader title="Actions" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, gap: 14 }}>
                <TouchableOpacity onPress={handleTestNotification}>
                  <Row
                    icon="notifications-outline" iconColor="#00d4ff" iconBg="#00d4ff22"
                    label="Send Test Notification"
                    sub="Fires a local notification immediately"
                  />
                </TouchableOpacity>
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <TouchableOpacity onPress={() => { haptic.tap(); retryRegister(); }}>
                  <Row
                    icon="cloud-upload-outline" iconColor="#10b981" iconBg="#10b98122"
                    label="Re-register Push Token"
                    sub="Force re-send token to Frigate server"
                  />
                </TouchableOpacity>
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <TouchableOpacity onPress={() => { haptic.tap(); webviewRef.current?.reload(); setSettingsOpen(false); }}>
                  <Row
                    icon="refresh" iconColor="#a855f7" iconBg="#a855f722"
                    label="Reload"
                    sub="Refresh the Frigate web app"
                  />
                </TouchableOpacity>
              </View>

              {/* ── SIGN OUT ──────────────────────────────────── */}
              <View style={{ marginTop: 8 }}>
                <TouchableOpacity
                  onPress={handleLogout}
                  style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14 }}
                >
                  <Row
                    icon="log-out" iconColor="#ef4444" iconBg="#ef444422"
                    label="Sign Out"
                  />
                </TouchableOpacity>
              </View>

            </ScrollView>
          </View>
        </SafeAreaView>
      </Modal>
    </View>
  );
}
