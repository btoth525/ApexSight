import { useRef, useState, useCallback, useEffect } from "react";
import {
  View, Text, TouchableOpacity, ActivityIndicator,
  Alert, Modal, ScrollView, TextInput, Animated,
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

// ─── JS injected on every page load ─────────────────────────────────────────
// • Removes disablePictureInPicture so iOS PiP works on Frigate's video tiles
// • MutationObserver re-applies to any video element Frigate adds dynamically
// • Requests PiP automatically when the user backgrounds the app
// • x-webkit-airplay so AirPlay icon appears in the native video controls
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

// ─── Helpers ─────────────────────────────────────────────────────────────────

function Row({
  icon, iconColor, iconBg, label, sub, right,
}: {
  icon: string; iconColor: string; iconBg: string;
  label: string; sub?: string; right?: React.ReactNode;
}) {
  return (
    <View style={{ flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 2 }}>
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
    <Text style={{
      color: "#475569", fontSize: 11, fontWeight: "700",
      textTransform: "uppercase", letterSpacing: 0.8,
      marginTop: 20, marginBottom: 6,
    }}>
      {title}
    </Text>
  );
}

function Divider() {
  return <View style={{ height: 1, backgroundColor: "#1e293b", marginVertical: 2 }} />;
}

// Convert apex:// deep-link → Frigate web URL (standard path routing, no hash)
// apex://cameras/driveway  →  {baseUrl}/cameras/driveway
// apex://review            →  {baseUrl}/review
// apex://clip/EVENT_ID     →  {baseUrl}/clip/EVENT_ID
function deeplinkToFrigateUrl(apexUrl: string, baseUrl: string): string | null {
  try {
    const parsed = Linking.parse(apexUrl);
    const host = parsed.hostname ?? "";
    const path = parsed.path ? parsed.path.replace(/^\//, "") : "";
    if (!host) return null;
    const route = path ? `${host}/${path}` : host;
    const qs = parsed.queryParams
      ? "?" + Object.entries(parsed.queryParams).map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`).join("&")
      : "";
    return `${baseUrl}/${route}${qs}`;
  } catch {
    return null;
  }
}

// ─── Main component ───────────────────────────────────────────────────────────

type ServerStatus = "idle" | "checking" | "online" | "auth" | "offline";

export default function BrowserScreen() {
  const { baseUrl, token, username, setBaseUrl, setAuth, logout } = useAuthStore();
  const router = useRouter();
  const webviewRef = useRef<WebView>(null);
  const insets = useSafeAreaInsets();

  // Keep screen on while watching live cameras
  useKeepAwake();

  const [cookieReady, setCookieReady]   = useState(false);
  const [loading, setLoading]           = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Server URL editing
  const [editingUrl, setEditingUrl] = useState(false);
  const [urlDraft, setUrlDraft]     = useState(baseUrl);

  // Credential change
  const [changingCreds, setChangingCreds] = useState(false);
  const [userDraft, setUserDraft]         = useState("");
  const [passDraft, setPassDraft]         = useState("");
  const [credError, setCredError]         = useState("");
  const [credLoading, setCredLoading]     = useState(false);
  const [showPass, setShowPass]           = useState(false);

  // Server reachability
  const [serverStatus, setServerStatus] = useState<ServerStatus>("idle");

  // ── Inject auth cookie before WebView loads ─────────────────────────────
  useEffect(() => {
    const inject = async () => {
      if (token && token !== "session" && baseUrl) {
        try {
          const { hostname, protocol } = new URL(baseUrl);
          await CookieManager.set(baseUrl, {
            name: "frigate_token", value: token,
            domain: hostname, path: "/",
            secure: protocol === "https:", httpOnly: false, version: "1",
          });
        } catch {}
      }
      setCookieReady(true);
    };
    inject();
  }, [baseUrl, token]);

  // ── Probe server when settings opens ────────────────────────────────────
  useEffect(() => {
    if (!settingsOpen) return;
    setServerStatus("checking");
    apiClient.get("/config")
      .then(() => setServerStatus("online"))
      .catch((err) => {
        if (err.response?.status === 401) setServerStatus("auth");
        else setServerStatus("offline");
      });
  }, [settingsOpen]);

  // ── Deep-link handler ────────────────────────────────────────────────────
  const navigateDeeplink = useCallback((url: string) => {
    const frigateUrl = deeplinkToFrigateUrl(url, baseUrl);
    if (!frigateUrl) return;
    setSettingsOpen(false);
    setTimeout(() => {
      webviewRef.current?.injectJavaScript(
        `window.location.href = ${JSON.stringify(frigateUrl)}; true;`
      );
    }, 500);
  }, [baseUrl]);

  useEffect(() => {
    const sub = Linking.addEventListener("url", ({ url }) => navigateDeeplink(url));
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
    setServerStatus("idle");
    setTimeout(() => webviewRef.current?.reload(), 300);
  };

  // ── Credential change (re-login with new username/password) ─────────────
  const handleSaveCreds = async () => {
    if (!userDraft.trim() || !passDraft.trim()) {
      setCredError("Please enter both username and password.");
      return;
    }
    setCredLoading(true);
    setCredError("");
    try {
      const res = await apiClient.post("/login", { user: userDraft.trim(), password: passDraft });
      if (res.status !== 200) throw new Error("Login failed");

      // Extract token — try response header first, then retry from cookie jar
      let newToken = "session";
      const rawCookie = res.headers?.["set-cookie"];
      if (rawCookie) {
        const str = Array.isArray(rawCookie) ? rawCookie.join("; ") : rawCookie;
        const m = str.match(/frigate_token=([^;,\s]+)/);
        if (m?.[1]) newToken = m[1];
      }
      if (newToken === "session") {
        for (let i = 0; i < 5; i++) {
          await new Promise((r) => setTimeout(r, 150));
          const cookies = await CookieManager.get(baseUrl);
          const val = cookies["frigate_token"]?.value;
          if (val && val.length > 10) { newToken = val; break; }
        }
      }

      const name = res.data?.user?.name ?? userDraft.trim();
      await setAuth(newToken, name);
      haptic.success();
      setChangingCreds(false);
      setUserDraft("");
      setPassDraft("");
      setTimeout(() => webviewRef.current?.reload(), 300);
    } catch (e: any) {
      haptic.error();
      if (e.response?.status === 401) setCredError("Invalid username or password.");
      else setCredError("Could not connect. Check server URL.");
    } finally {
      setCredLoading(false);
    }
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

  // ── Status dot helper ────────────────────────────────────────────────────
  const statusDot = () => {
    if (serverStatus === "checking") return (
      <ActivityIndicator size="small" color="#94a3b8" style={{ transform: [{ scale: 0.6 }] }} />
    );
    const colors: Record<ServerStatus, string> = {
      idle: "#334155", checking: "#334155",
      online: "#10b981", auth: "#f59e0b", offline: "#ef4444",
    };
    const labels: Record<ServerStatus, string> = {
      idle: "Tap to check", checking: "Checking…",
      online: "Connected", auth: "Session expired", offline: "Unreachable",
    };
    return (
      <View style={{ flexDirection: "row", alignItems: "center", gap: 5 }}>
        <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: colors[serverStatus] }} />
        <Text style={{ color: colors[serverStatus], fontSize: 12, fontWeight: "600" }}>
          {labels[serverStatus]}
        </Text>
      </View>
    );
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

      {/* Frigate PWA — full screen, safe area insets only */}
      <View style={{ flex: 1, paddingTop: insets.top, paddingBottom: insets.bottom, backgroundColor: "#000" }}>
        <WebView
          ref={webviewRef}
          source={{ uri: baseUrl }}
          style={{ flex: 1 }}
          sharedCookiesEnabled={true}
          allowsInlineMediaPlayback={true}
          mediaPlaybackRequiresUserAction={false}
          allowsFullscreenVideo={true}
          allowsAirPlayForMediaPlayback={true}
          allowsBackForwardNavigationGestures={true}
          pullToRefreshEnabled={true}
          injectedJavaScript={VIEWER_JS}
          onNavigationStateChange={handleNavChange}
          onLoadStart={() => setLoading(true)}
          onLoadEnd={() => setLoading(false)}
        />
      </View>

      {/* Loading splash */}
      {loading && (
        <View style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
          <View style={{ width: 64, height: 64, borderRadius: 18, backgroundColor: "#1e293b", alignItems: "center", justifyContent: "center", marginBottom: 16, shadowColor: "#00d4ff", shadowOpacity: 0.3, shadowRadius: 16, shadowOffset: { width: 0, height: 0 } }}>
            <Ionicons name="shield" size={32} color="#00d4ff" />
          </View>
          <ActivityIndicator color="#00d4ff" />
          <Text style={{ color: "#64748b", marginTop: 12, fontSize: 13, letterSpacing: 0.3 }}>Connecting to Frigate…</Text>
        </View>
      )}

      {/* Floating settings pill — bottom-right corner above Frigate nav */}
      <TouchableOpacity
        onPress={() => { haptic.tap(); setSettingsOpen(true); }}
        style={{
          position: "absolute",
          bottom: insets.bottom + 82,
          right: 14,
          flexDirection: "row",
          alignItems: "center",
          gap: 5,
          paddingHorizontal: 12,
          paddingVertical: 7,
          borderRadius: 20,
          backgroundColor: "#0f172aee",
          borderWidth: 1,
          borderColor: "#1e293b",
        }}
      >
        <Ionicons name="settings-outline" size={13} color="#64748b" />
        <Text style={{ color: "#64748b", fontSize: 12, fontWeight: "600" }}>Apex</Text>
      </TouchableOpacity>

      {/* ── Settings bottom sheet ──────────────────────────────────────── */}
      <Modal
        visible={settingsOpen}
        transparent
        animationType="slide"
        onRequestClose={() => setSettingsOpen(false)}
      >
        <TouchableOpacity
          style={{ flex: 1, backgroundColor: "#00000099" }}
          activeOpacity={1}
          onPress={() => setSettingsOpen(false)}
        />

        <SafeAreaView style={{ backgroundColor: "#0a0f1e" }} edges={["bottom"]}>
          <View style={{
            backgroundColor: "#0a0f1e",
            borderTopLeftRadius: 24, borderTopRightRadius: 24,
            borderTopWidth: 1, borderColor: "#1e293b",
            maxHeight: "85%",
          }}>

            {/* Drag handle + title */}
            <View style={{ paddingTop: 12, paddingHorizontal: 20, paddingBottom: 8 }}>
              <View style={{ width: 40, height: 4, borderRadius: 2, backgroundColor: "#334155", alignSelf: "center", marginBottom: 16 }} />
              <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between" }}>
                <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
                  <View style={{ width: 28, height: 28, borderRadius: 7, backgroundColor: "#00d4ff22", alignItems: "center", justifyContent: "center" }}>
                    <Ionicons name="shield" size={15} color="#00d4ff" />
                  </View>
                  <Text style={{ color: "#f1f5f9", fontSize: 17, fontWeight: "700", letterSpacing: -0.3 }}>Apex</Text>
                </View>
                <TouchableOpacity onPress={() => setSettingsOpen(false)} style={{ padding: 4 }}>
                  <Ionicons name="close" size={20} color="#475569" />
                </TouchableOpacity>
              </View>
            </View>

            <ScrollView
              style={{ paddingHorizontal: 16 }}
              contentContainerStyle={{ paddingBottom: 32 }}
              showsVerticalScrollIndicator={false}
            >

              {/* ── ACCOUNT ──────────────────────────────────────── */}
              <SectionHeader title="Account" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, overflow: "hidden" }}>

                {/* Current user row */}
                <View style={{ padding: 14 }}>
                  <Row
                    icon="person-circle-outline" iconColor="#a855f7" iconBg="#a855f722"
                    label={username ?? "Unknown"}
                    sub="Logged in to Frigate"
                    right={
                      !changingCreds ? (
                        <TouchableOpacity
                          onPress={() => { setUserDraft(username ?? ""); setPassDraft(""); setCredError(""); setChangingCreds(true); }}
                          style={{ flexDirection: "row", alignItems: "center", gap: 4, backgroundColor: "#334155", borderRadius: 8, paddingHorizontal: 10, paddingVertical: 5 }}
                        >
                          <Text style={{ color: "#94a3b8", fontSize: 12, fontWeight: "600" }}>Change</Text>
                        </TouchableOpacity>
                      ) : null
                    }
                  />
                </View>

                {/* Inline credential change form */}
                {changingCreds && (
                  <>
                    <View style={{ height: 1, backgroundColor: "#334155" }} />
                    <View style={{ padding: 14, gap: 10 }}>
                      <Text style={{ color: "#94a3b8", fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.5 }}>New Credentials</Text>

                      {/* Username */}
                      <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#0f172a", borderRadius: 10, paddingHorizontal: 12, gap: 8, borderWidth: 1, borderColor: "#334155" }}>
                        <Ionicons name="person-outline" size={15} color="#475569" />
                        <TextInput
                          style={{ flex: 1, paddingVertical: 11, color: "#f1f5f9", fontSize: 14 }}
                          placeholder="Username"
                          placeholderTextColor="#475569"
                          value={userDraft}
                          onChangeText={setUserDraft}
                          autoCapitalize="none"
                          autoCorrect={false}
                          textContentType="username"
                        />
                      </View>

                      {/* Password */}
                      <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#0f172a", borderRadius: 10, paddingHorizontal: 12, gap: 8, borderWidth: 1, borderColor: "#334155" }}>
                        <Ionicons name="lock-closed-outline" size={15} color="#475569" />
                        <TextInput
                          style={{ flex: 1, paddingVertical: 11, color: "#f1f5f9", fontSize: 14 }}
                          placeholder="Password"
                          placeholderTextColor="#475569"
                          value={passDraft}
                          onChangeText={setPassDraft}
                          secureTextEntry={!showPass}
                          textContentType="password"
                        />
                        <TouchableOpacity onPress={() => setShowPass((s) => !s)}>
                          <Ionicons name={showPass ? "eye-off-outline" : "eye-outline"} size={15} color="#475569" />
                        </TouchableOpacity>
                      </View>

                      {credError ? (
                        <View style={{ flexDirection: "row", alignItems: "center", gap: 5 }}>
                          <Ionicons name="warning" size={12} color="#ef4444" />
                          <Text style={{ color: "#ef4444", fontSize: 12 }}>{credError}</Text>
                        </View>
                      ) : null}

                      <View style={{ flexDirection: "row", gap: 8, marginTop: 2 }}>
                        <TouchableOpacity
                          onPress={() => { setChangingCreds(false); setCredError(""); }}
                          style={{ flex: 1, backgroundColor: "#334155", borderRadius: 10, paddingVertical: 11, alignItems: "center" }}
                        >
                          <Text style={{ color: "#94a3b8", fontWeight: "600", fontSize: 14 }}>Cancel</Text>
                        </TouchableOpacity>
                        <TouchableOpacity
                          onPress={handleSaveCreds}
                          disabled={credLoading}
                          style={{ flex: 2, backgroundColor: "#00d4ff", borderRadius: 10, paddingVertical: 11, alignItems: "center" }}
                        >
                          {credLoading
                            ? <ActivityIndicator color="#0a0f1e" size="small" />
                            : <Text style={{ color: "#0a0f1e", fontWeight: "700", fontSize: 14 }}>Save & Re-login</Text>
                          }
                        </TouchableOpacity>
                      </View>
                    </View>
                  </>
                )}
              </View>

              {/* ── SERVER ───────────────────────────────────────── */}
              <SectionHeader title="Server" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, overflow: "hidden" }}>

                {editingUrl ? (
                  <View style={{ padding: 14, gap: 10 }}>
                    <TextInput
                      style={{ color: "#f1f5f9", fontSize: 14, backgroundColor: "#0f172a", borderRadius: 10, padding: 12, borderWidth: 1, borderColor: "#334155" }}
                      value={urlDraft}
                      onChangeText={setUrlDraft}
                      autoCapitalize="none"
                      autoCorrect={false}
                      keyboardType="url"
                      placeholder="https://your-frigate-host.com"
                      placeholderTextColor="#475569"
                    />
                    <View style={{ flexDirection: "row", gap: 8 }}>
                      <TouchableOpacity
                        onPress={() => setEditingUrl(false)}
                        style={{ flex: 1, backgroundColor: "#334155", borderRadius: 10, paddingVertical: 11, alignItems: "center" }}
                      >
                        <Text style={{ color: "#94a3b8", fontWeight: "600" }}>Cancel</Text>
                      </TouchableOpacity>
                      <TouchableOpacity
                        onPress={handleSaveUrl}
                        style={{ flex: 2, backgroundColor: "#00d4ff", borderRadius: 10, paddingVertical: 11, alignItems: "center" }}
                      >
                        <Text style={{ color: "#0a0f1e", fontWeight: "700" }}>Save & Reload</Text>
                      </TouchableOpacity>
                    </View>
                  </View>
                ) : (
                  <View style={{ padding: 14, gap: 12 }}>
                    {/* URL row */}
                    <Row
                      icon="globe-outline" iconColor="#00d4ff" iconBg="#00d4ff22"
                      label={baseUrl.replace(/^https?:\/\//, "")}
                      sub="Frigate NVR server"
                      right={
                        <TouchableOpacity
                          onPress={() => { setUrlDraft(baseUrl); setEditingUrl(true); }}
                          style={{ backgroundColor: "#334155", borderRadius: 8, paddingHorizontal: 10, paddingVertical: 5, flexDirection: "row", alignItems: "center", gap: 4 }}
                        >
                          <Ionicons name="pencil-outline" size={12} color="#94a3b8" />
                          <Text style={{ color: "#94a3b8", fontSize: 12, fontWeight: "600" }}>Edit</Text>
                        </TouchableOpacity>
                      }
                    />
                    {/* Status row */}
                    <View style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
                      <View style={{ width: 34, height: 34, borderRadius: 8, backgroundColor: "#0f172a", alignItems: "center", justifyContent: "center" }}>
                        <Ionicons name="pulse-outline" size={17} color="#475569" />
                      </View>
                      <View style={{ flex: 1 }}>
                        <Text style={{ color: "#f1f5f9", fontSize: 15, fontWeight: "500" }}>Connection</Text>
                      </View>
                      {statusDot()}
                    </View>
                  </View>
                )}
              </View>

              {/* ── HOME ASSISTANT DEEP LINKS ─────────────────────── */}
              <SectionHeader title="Home Assistant Deep Links" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14, gap: 12 }}>
                <Row
                  icon="link-outline" iconColor="#f59e0b" iconBg="#f59e0b22"
                  label="Open Apex from HA automations"
                  sub={'Add url: "apex://..." to your notify action data'}
                />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                {[
                  { route: "cameras/{name}",  desc: "Live camera view" },
                  { route: "review",           desc: "Event review page" },
                  { route: "clip/{event_id}",  desc: "Specific event clip" },
                ].map(({ route, desc }) => (
                  <View key={route} style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
                    <View style={{ flex: 1 }}>
                      <Text style={{ color: "#00d4ff", fontSize: 13, fontFamily: "monospace", marginBottom: 1 }}>
                        apex://{route}
                      </Text>
                      <Text style={{ color: "#475569", fontSize: 11 }}>{desc}</Text>
                    </View>
                  </View>
                ))}
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <View style={{ backgroundColor: "#0f172a", borderRadius: 8, padding: 10 }}>
                  <Text style={{ color: "#64748b", fontSize: 11, lineHeight: 17 }}>
                    <Text style={{ color: "#94a3b8", fontWeight: "600" }}>Example HA action:{"\n"}</Text>
                    <Text style={{ color: "#00d4ff", fontFamily: "monospace" }}>
                      {"data:\n  url: \"apex://cameras/driveway\""}
                    </Text>
                  </Text>
                </View>
              </View>

              {/* ── VIEWER ───────────────────────────────────────────── */}
              <SectionHeader title="Viewer" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14, gap: 10 }}>
                <Row icon="phone-portrait-outline" iconColor="#10b981" iconBg="#10b98122"
                  label="Picture-in-Picture" sub="Auto-activates when you background the app" />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <Row icon="tv-outline" iconColor="#10b981" iconBg="#10b98122"
                  label="AirPlay" sub="Use native video controls to stream to Apple TV" />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <Row icon="sunny-outline" iconColor="#10b981" iconBg="#10b98122"
                  label="Keep Screen On" sub="Display stays awake while Apex is open" />
              </View>

              {/* ── ACTIONS ──────────────────────────────────────────── */}
              <SectionHeader title="Actions" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}>
                <TouchableOpacity onPress={() => { haptic.tap(); webviewRef.current?.reload(); setSettingsOpen(false); }}>
                  <Row
                    icon="refresh-outline" iconColor="#a855f7" iconBg="#a855f722"
                    label="Reload Frigate"
                    sub="Force refresh the web app"
                  />
                </TouchableOpacity>
              </View>

              {/* ── SIGN OUT ─────────────────────────────────────────── */}
              <View style={{ marginTop: 8, marginBottom: 4 }}>
                <TouchableOpacity
                  onPress={handleLogout}
                  style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}
                >
                  <Row
                    icon="log-out-outline" iconColor="#ef4444" iconBg="#ef444422"
                    label="Sign Out"
                    sub="Clears your session from this device"
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
