import { useRef, useState, useCallback, useEffect } from "react";
import {
  View, Text, TouchableOpacity, ActivityIndicator,
  Alert, Modal, ScrollView, TextInput,
} from "react-native";
import { WebView, WebViewNavigation } from "react-native-webview";
import { SafeAreaView, useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import CookieManager from "@react-native-cookies/cookies";
import { useRouter } from "expo-router";
import * as Linking from "expo-linking";
import { useKeepAwake } from "expo-keep-awake";
import { useAuthStore } from "@/stores/authStore";
import { haptic } from "@/utils/haptics";
import { apiClient } from "@/utils/apiClient";

// JS injected on every page load:
// • Removes disablePictureInPicture from all video elements so iOS PiP works
// • Watches for new video elements added dynamically (Frigate's live view)
// • Requests PiP automatically when the app is sent to background
const VIEWER_JS = `
(function() {
  function enhanceVideos() {
    document.querySelectorAll('video').forEach(function(v) {
      v.removeAttribute('disablePictureInPicture');
      v.setAttribute('playsinline', '');
      v.setAttribute('webkit-playsinline', '');
      v.setAttribute('x-webkit-airplay', 'allow');
    });
  }
  enhanceVideos();
  var mo = new MutationObserver(enhanceVideos);
  mo.observe(document.body, { childList: true, subtree: true });

  // Auto-PiP when user backgrounds the app
  document.addEventListener('visibilitychange', function() {
    if (document.visibilityState !== 'hidden') return;
    var vs = document.querySelectorAll('video');
    for (var i = 0; i < vs.length; i++) {
      var v = vs[i];
      if (v.readyState >= 2 && document.pictureInPictureEnabled && !document.pictureInPictureElement) {
        v.requestPictureInPicture().catch(function(){});
        break;
      }
    }
  });
})();
true;
`;

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

// Convert an apex:// deep-link to the corresponding Frigate web URL.
// apex://cameras/driveway   → {baseUrl}/#/cameras/driveway
// apex://review             → {baseUrl}/#/review
// apex://clip/EVENT_ID      → {baseUrl}/#/clip/EVENT_ID
function deeplinkToFrigateUrl(apexUrl: string, baseUrl: string): string | null {
  try {
    const parsed = Linking.parse(apexUrl);
    const host = parsed.hostname ?? "";
    const path = parsed.path ? parsed.path.replace(/^\//, "") : "";
    if (!host) return null;
    const route = path ? `${host}/${path}` : host;
    const qs = parsed.queryParams
      ? "?" + Object.entries(parsed.queryParams).map(([k, v]) => `${k}=${v}`).join("&")
      : "";
    return `${baseUrl}/#/${route}${qs}`;
  } catch {
    return null;
  }
}

export default function BrowserScreen() {
  const { baseUrl, token, setBaseUrl, logout } = useAuthStore();
  const router = useRouter();
  const webviewRef = useRef<WebView>(null);
  const insets = useSafeAreaInsets();

  // Keep the screen on while the user is watching live cameras
  useKeepAwake();

  const [cookieReady, setCookieReady] = useState(false);
  const [loading, setLoading] = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Server URL editing
  const [editingUrl, setEditingUrl] = useState(false);
  const [urlDraft, setUrlDraft] = useState(baseUrl);

  // ── Inject auth cookie before WebView loads ──────────────────────────────
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

  // ── Deep-link handler ────────────────────────────────────────────────────
  // Handles apex:// URLs both when the app is already running and when it is
  // cold-started from a Home Assistant notification tap.
  const navigateDeeplink = useCallback((url: string) => {
    const frigateUrl = deeplinkToFrigateUrl(url, baseUrl);
    if (!frigateUrl) return;
    setSettingsOpen(false);
    // Small delay so the WebView has finished loading if this is a cold start
    setTimeout(() => {
      webviewRef.current?.injectJavaScript(
        `window.location.href = ${JSON.stringify(frigateUrl)}; true;`
      );
    }, 500);
  }, [baseUrl]);

  useEffect(() => {
    // App already open — listen for incoming links
    const sub = Linking.addEventListener("url", ({ url }) => navigateDeeplink(url));
    // App cold-started from a deep link
    Linking.getInitialURL().then((url) => {
      if (url) setTimeout(() => navigateDeeplink(url), 1500);
    });
    return () => sub.remove();
  }, [navigateDeeplink]);

  // ── Server URL save ──────────────────────────────────────────────────────
  const handleSaveUrl = async () => {
    const clean = urlDraft.trim().replace(/\/$/, "");
    if (!clean) return;
    await setBaseUrl(clean);
    setEditingUrl(false);
    setTimeout(() => webviewRef.current?.reload(), 300);
  };

  // ── Sign out ─────────────────────────────────────────────────────────────
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

  const handleNavChange = useCallback((_nav: WebViewNavigation) => {}, []);

  if (!cookieReady) {
    return (
      <View style={{ flex: 1, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
        <ActivityIndicator color="#00d4ff" size="large" />
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: "#000" }}>
      {/* Safe-area so Frigate PWA clears status bar and home indicator */}
      <View style={{ flex: 1, paddingTop: insets.top, paddingBottom: insets.bottom, backgroundColor: "#000" }}>
        <WebView
          ref={webviewRef}
          source={{ uri: baseUrl }}
          style={{ flex: 1 }}
          // Cookie & media
          sharedCookiesEnabled={true}
          allowsInlineMediaPlayback={true}
          mediaPlaybackRequiresUserAction={false}
          allowsFullscreenVideo={true}
          allowsAirPlayForMediaPlayback={true}
          // Navigation feel
          allowsBackForwardNavigationGestures={true}
          pullToRefreshEnabled={true}
          // Inject PiP + AirPlay enablers once the page is ready
          injectedJavaScript={VIEWER_JS}
          onNavigationStateChange={handleNavChange}
          onLoadStart={() => setLoading(true)}
          onLoadEnd={() => setLoading(false)}
        />
      </View>

      {/* Loading overlay */}
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

      {/* ── Settings modal ──────────────────────────────────────────────── */}
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
          <View style={{ backgroundColor: "#0f172a", borderTopLeftRadius: 20, borderTopRightRadius: 20, borderTopWidth: 1, borderColor: "#1e293b", maxHeight: "80%" }}>

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
              contentContainerStyle={{ paddingBottom: 28, gap: 0 }}
              showsVerticalScrollIndicator={false}
            >

              {/* ── SERVER ──────────────────────────────────────── */}
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
                    label={baseUrl.replace(/^https?:\/\//, "")}
                    sub="Tap to change server URL"
                    right={
                      <TouchableOpacity onPress={() => { setUrlDraft(baseUrl); setEditingUrl(true); }}>
                        <Ionicons name="pencil-outline" size={18} color="#475569" />
                      </TouchableOpacity>
                    }
                  />
                )}
              </View>

              {/* ── HOME ASSISTANT DEEP LINKS ───────────────────── */}
              <SectionHeader title="Home Assistant Deep Links" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, gap: 12 }}>
                <Row
                  icon="link-outline" iconColor="#f59e0b" iconBg="#f59e0b22"
                  label="Open Apex from HA automations"
                  sub="Use these URLs in notify.mobile_app actions"
                />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                {[
                  { route: "cameras/{name}", desc: "Live view for a camera" },
                  { route: "review",         desc: "Event review page" },
                  { route: "clip/{event_id}", desc: "Specific event clip" },
                ].map(({ route, desc }) => (
                  <View key={route} style={{ gap: 2 }}>
                    <Text style={{ color: "#00d4ff", fontSize: 13, fontFamily: "monospace" }}>
                      apex://{route}
                    </Text>
                    <Text style={{ color: "#64748b", fontSize: 12 }}>{desc}</Text>
                  </View>
                ))}
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <Text style={{ color: "#475569", fontSize: 11, lineHeight: 16 }}>
                  In your HA automation, add{" "}
                  <Text style={{ color: "#94a3b8", fontFamily: "monospace" }}>url: "apex://cameras/driveway"</Text>
                  {" "}to the notify action data.
                </Text>
              </View>

              {/* ── ACTIONS ─────────────────────────────────────── */}
              <SectionHeader title="Actions" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 12, padding: 14, gap: 14 }}>
                <TouchableOpacity onPress={() => { haptic.tap(); webviewRef.current?.reload(); setSettingsOpen(false); }}>
                  <Row
                    icon="refresh" iconColor="#a855f7" iconBg="#a855f722"
                    label="Reload"
                    sub="Refresh the Frigate web app"
                  />
                </TouchableOpacity>
              </View>

              {/* ── SIGN OUT ────────────────────────────────────── */}
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
