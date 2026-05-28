import { useRef, useState, useCallback, useEffect } from "react";
import {
  View, Text, TouchableOpacity, ActivityIndicator,
  Alert, Modal, ScrollView, TextInput,
  PanResponder, Animated, Share, useWindowDimensions,
} from "react-native";
import { WebView, WebViewNavigation } from "react-native-webview";
import { SafeAreaView, useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import CookieManager from "@react-native-cookies/cookies";
import { useRouter } from "expo-router";
import * as Linking from "expo-linking";
import { useKeepAwake } from "expo-keep-awake";
import Constants from "expo-constants";
import { Accelerometer } from "expo-sensors";
import NetInfo from "@react-native-community/netinfo";
import { useAuthStore } from "@/stores/authStore";
import { haptic } from "@/utils/haptics";
import { apiClient } from "@/utils/apiClient";
import { useFrigateEvents } from "@/hooks/useFrigateEvents";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";

// ─── JS injected on every page load ─────────────────────────────────────────
const VIEWER_JS = `
(function() {
  // ── Video enhancements ──────────────────────────────────────────────────
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

  // ── Ready signal — only fire once Frigate's React app has painted on screen.
  // DOM updates and GPU paint happen on different timelines in WKWebView.
  // We use requestAnimationFrame so the signal fires AFTER the browser has
  // actually committed the frame to screen, preventing "DOM ready but still black".
  var readySent = false;
  function post(type) {
    try { window.ReactNativeWebView.postMessage(JSON.stringify({ type: type })); } catch(e) {}
  }
  function fireReady() {
    if (readySent) return;
    readySent = true;
    contentObs.disconnect();
    post('frigateReady');
  }
  function checkReady() {
    if (readySent) return;
    var root = document.getElementById('root') || document.body;
    if (!root) return;
    var hasUi = root.querySelector('button, canvas, video, img, a, input, [role="button"]') !== null;
    var hasText = root.innerText && root.innerText.trim().length > 30;
    if (hasUi && hasText) {
      // Wait for the browser to actually paint the frame before signalling
      if (window.requestAnimationFrame) {
        requestAnimationFrame(function() { requestAnimationFrame(fireReady); });
      } else {
        setTimeout(fireReady, 100);
      }
    }
  }
  var contentObs = new MutationObserver(checkReady);
  contentObs.observe(document.documentElement, { childList: true, subtree: true });
  checkReady();
  // Hard fallback: surface the app after 8s regardless
  setTimeout(fireReady, 8000);
})();
true;
`;

// Deep-link routes shown in settings with descriptions
const DEEP_LINKS = [
  { route: "cameras/{name}",   desc: "Live view for a specific camera",  example: "cameras/driveway" },
  { route: "review",           desc: "Event review page",                 example: "review" },
  { route: "clip/{event_id}",  desc: "Jump to a specific event clip",     example: "clip/abc123" },
  { route: "events",           desc: "All events feed",                   example: "events" },
  { route: "recordings",       desc: "Recordings browser",                example: "recordings" },
  { route: "system",           desc: "System stats & logs",               example: "system" },
];

// ─── Convert apex:// → Frigate web URL (standard path routing) ──────────────
function deeplinkToFrigateUrl(apexUrl: string, baseUrl: string): string | null {
  try {
    const parsed = Linking.parse(apexUrl);
    const host = parsed.hostname ?? "";
    const path = parsed.path ? parsed.path.replace(/^\//, "") : "";
    if (!host) return null;
    const route = path ? `${host}/${path}` : host;
    const qs = parsed.queryParams
      ? "?" + Object.entries(parsed.queryParams)
          .map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`)
          .join("&")
      : "";
    return `${baseUrl}/${route}${qs}`;
  } catch {
    return null;
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
function Row({ icon, iconColor, iconBg, label, sub, right }: {
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
    <Text style={{ color: "#475569", fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.8, marginTop: 20, marginBottom: 6 }}>
      {title}
    </Text>
  );
}

type ServerStatus = "unknown" | "online" | "auth" | "offline";

// ─── Main component ───────────────────────────────────────────────────────────
export default function BrowserScreen() {
  const { baseUrl, token, username, setBaseUrl, setAuth, logout } = useAuthStore();
  const router = useRouter();
  const webviewRef = useRef<WebView>(null);
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  const isLandscape = width > height;

  useKeepAwake();

  const [cookieReady, setCookieReady]   = useState(false);
  const [loading, setLoading]           = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [serverStatus, setServerStatus] = useState<ServerStatus>("unknown");
  const [isOffline, setIsOffline]       = useState(false);
  const [errorUrlDraft, setErrorUrlDraft] = useState("");
  const [showSkip, setShowSkip]           = useState(false);
  const readyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const skipTimerRef  = useRef<ReturnType<typeof setTimeout> | null>(null);

  // cleanup on unmount
  useEffect(() => () => {
    if (readyTimerRef.current) clearTimeout(readyTimerRef.current);
    if (skipTimerRef.current)  clearTimeout(skipTimerRef.current);
  }, []);

  // Camera quick-switcher
  const [cameras, setCameras]             = useState<string[]>([]);
  const [cameraMenuOpen, setCameraMenuOpen] = useState(false);

  // Motion alert toast
  const [toastMsg, setToastMsg]       = useState<string | null>(null);
  const toastAnim                     = useRef(new Animated.Value(-80)).current;
  const toastTimerRef                 = useRef<ReturnType<typeof setTimeout> | null>(null);

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

  // ── Shake to reload (defensive — never let a sensor issue crash the screen) ─
  useEffect(() => {
    let sub: { remove: () => void } | null = null;
    let lastShake = 0;
    try {
      Accelerometer.setUpdateInterval(200);
      sub = Accelerometer.addListener(({ x, y, z }) => {
        const mag = Math.sqrt(x * x + y * y + z * z);
        if (mag > 2.8) {
          const now = Date.now();
          if (now - lastShake > 3000) {
            lastShake = now;
            haptic.heavy();
            webviewRef.current?.reload();
          }
        }
      });
    } catch {}
    return () => { try { sub?.remove(); } catch {} };
  }, []);

  // ── Motion alert toast ──────────────────────────────────────────────────
  const showToast = useCallback((msg: string) => {
    if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
    // If already visible, just swap the message; otherwise slide in from top
    setToastMsg(msg);
    Animated.timing(toastAnim, { toValue: 0, duration: 250, useNativeDriver: true }).start();
    toastTimerRef.current = setTimeout(() => {
      Animated.timing(toastAnim, { toValue: -80, duration: 300, useNativeDriver: true }).start(() => setToastMsg(null));
    }, 4000);
  }, [toastAnim]);

  useFrigateEvents(useCallback((data: unknown) => {
    const ev = data as { type?: string; after?: { camera?: string; label?: string; score?: number } };
    if (ev?.type !== "new") return;
    const { camera, label, score } = ev.after ?? {};
    if (!label || (score !== undefined && score < 0.6)) return;
    if (settingsOpen) return;
    haptic.medium();
    showToast(`${getLabelEmoji(label)} ${formatLabel(label)} detected – ${(camera ?? "").replace(/_/g, " ")}`);
  }, [settingsOpen, showToast]));

  // cleanup toast timer on unmount
  useEffect(() => () => { if (toastTimerRef.current) clearTimeout(toastTimerRef.current); }, []);

  // ── Network connectivity — show banner + auto-retry on reconnect ────────
  useEffect(() => {
    const unsub = NetInfo.addEventListener((state) => {
      const connected = state.isConnected ?? true;
      const wasOffline = !connected;
      setIsOffline(!connected);
      // Auto-retry WebView when connectivity returns
      if (connected && serverStatus === "offline") {
        setServerStatus("unknown");
        setLoading(true);
        setTimeout(() => webviewRef.current?.reload(), 500);
      }
    });
    return () => unsub();
  }, [serverStatus]);

  // ── Fetch camera list after server comes online ──────────────────────────
  useEffect(() => {
    if (serverStatus !== "online") return;
    apiClient.get("/config").then((res) => {
      const cams = Object.keys(res.data?.cameras ?? {});
      if (cams.length > 0) setCameras(cams);
    }).catch(() => {});
  }, [serverStatus]);

  // ── Swipe-to-dismiss the settings panel ─────────────────────────────────
  const dismissSettings = useCallback(() => setSettingsOpen(false), []);
  const handlePan = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder:  (_, { dy }) => Math.abs(dy) > 5,
      onPanResponderRelease: (_, { dy, vy }) => {
        if (dy > 60 || vy > 0.8) dismissSettings();
      },
    })
  ).current;

  // ── Inject auth cookie before WebView loads ──────────────────────────────
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

  // ── Deep-link handler ────────────────────────────────────────────────────
  const navigateDeeplink = useCallback((url: string) => {
    const frigateUrl = deeplinkToFrigateUrl(url, baseUrl);
    if (!frigateUrl) return;
    setSettingsOpen(false);
    setTimeout(() => {
      webviewRef.current?.injectJavaScript(
        `window.location.href = ${JSON.stringify(frigateUrl)}; true;`
      );
    }, 400);
  }, [baseUrl]);

  useEffect(() => {
    const sub = Linking.addEventListener("url", ({ url }) => navigateDeeplink(url));
    Linking.getInitialURL().then((url) => {
      if (url) setTimeout(() => navigateDeeplink(url), 1500);
    });
    return () => sub.remove();
  }, [navigateDeeplink]);

  // ── Camera quick-switch ──────────────────────────────────────────────────
  const handleCameraSelect = (name: string) => {
    haptic.tap();
    setCameraMenuOpen(false);
    setTimeout(() => {
      webviewRef.current?.injectJavaScript(
        `window.location.href = ${JSON.stringify(`${baseUrl}/cameras/${name}`)}; true;`
      );
    }, 200);
  };

  // ── Server URL save ──────────────────────────────────────────────────────
  const handleSaveUrl = async () => {
    const clean = urlDraft.trim().replace(/\/$/, "");
    if (!clean) return;
    await setBaseUrl(clean);
    setEditingUrl(false);
    setServerStatus("unknown");
    setTimeout(() => webviewRef.current?.reload(), 300);
  };

  // ── Credential change ────────────────────────────────────────────────────
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

  // ── Copy / share a deep-link URL ─────────────────────────────────────────
  const handleShare = (route: string) => {
    haptic.tap();
    Share.share({ message: `apex://${route}` });
  };

  // ── Status helpers ────────────────────────────────────────────────────────
  const statusColor: Record<ServerStatus, string> = {
    unknown: "#334155", online: "#10b981", auth: "#f59e0b", offline: "#ef4444",
  };
  const statusLabel: Record<ServerStatus, string> = {
    unknown: "Loading…", online: "Connected", auth: "Session expired", offline: "Unreachable",
  };

  const appVersion = Constants.expoConfig?.version ?? "1.0";
  const buildNumber = (Constants.expoConfig?.ios as any)?.buildNumber ?? "1";

  // Guard: missing server URL → kick back to login (prevents black WebView from empty URI)
  if (!baseUrl || !baseUrl.startsWith("http")) {
    return (
      <View style={{ flex: 1, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center", padding: 24 }}>
        <View style={{ width: 64, height: 64, borderRadius: 18, backgroundColor: "#1e293b", alignItems: "center", justifyContent: "center", marginBottom: 16 }}>
          <Ionicons name="warning-outline" size={28} color="#f59e0b" />
        </View>
        <Text style={{ color: "#f1f5f9", fontSize: 16, fontWeight: "700", marginBottom: 8 }}>No server configured</Text>
        <Text style={{ color: "#64748b", fontSize: 13, textAlign: "center", marginBottom: 20 }}>
          Sign in again to enter your Frigate server URL.
        </Text>
        <TouchableOpacity
          onPress={async () => { await logout(); router.replace("/(auth)/login"); }}
          style={{ backgroundColor: "#00d4ff", borderRadius: 12, paddingVertical: 12, paddingHorizontal: 28 }}
        >
          <Text style={{ color: "#0a0f1e", fontWeight: "700" }}>Go to Sign In</Text>
        </TouchableOpacity>
      </View>
    );
  }

  if (!cookieReady) {
    return (
      <View style={{ flex: 1, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
        <ActivityIndicator color="#00d4ff" size="large" />
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: "#0a0f1e" }}>

      {/* Frigate PWA. Two safe-area-inset rules at play:
            1. iOS auto-adjusts the WKWebView scrollview for the status bar via
               contentInsetAdjustmentBehavior. We disable it ("never") because
               Frigate's CSS uses env(safe-area-inset-*) itself; both applied
               causes double-inset → content pushed off-screen → black at top.
            2. Our native wrapper has zero padding for the same reason.
          The splash overlay stays visible until VIEWER_JS posts frigateReady
          (React app actually mounted), with a long safety net to prevent any
          accidental "splash gone but app not painted" dark flash. */}
      <View style={{ flex: 1 }}>
        <WebView
          ref={webviewRef}
          source={{ uri: baseUrl }}
          style={{ flex: 1, backgroundColor: "#0a0f1e" }}
          automaticallyAdjustContentInsets={false}
          contentInsetAdjustmentBehavior="never"
          contentInset={{ top: 0, left: 0, right: 0, bottom: 0 }}
          originWhitelist={["*"]}
          sharedCookiesEnabled={true}
          allowsInlineMediaPlayback={true}
          mediaPlaybackRequiresUserAction={false}
          allowsFullscreenVideo={true}
          allowsAirPlayForMediaPlayback={true}
          allowsBackForwardNavigationGestures={true}
          pullToRefreshEnabled={true}
          injectedJavaScript={VIEWER_JS}
          applicationNameForUserAgent="ApexNative/1.0"
          onNavigationStateChange={useCallback((_: WebViewNavigation) => {}, [])}
          onLoadStart={() => {
            setLoading(true);
            setShowSkip(false);
            if (readyTimerRef.current) clearTimeout(readyTimerRef.current);
            if (skipTimerRef.current) clearTimeout(skipTimerRef.current);
            // After 6s of waiting, surface a "Tap to continue" button so the
            // user is never stuck behind the splash even if frigateReady never fires.
            skipTimerRef.current = setTimeout(() => setShowSkip(true), 6000);
            // Hard safety net — never let the splash hang past 12s.
            readyTimerRef.current = setTimeout(() => setLoading(false), 12000);
          }}
          onLoadEnd={() => {
            setServerStatus("online");
            // frigateReady (from VIEWER_JS) is the primary signal. This 3s
            // timer is a safety net for cases where the JS signal never arrives.
            if (readyTimerRef.current) clearTimeout(readyTimerRef.current);
            readyTimerRef.current = setTimeout(() => setLoading(false), 3000);
          }}
          onMessage={(event) => {
            try {
              const msg = JSON.parse(event.nativeEvent.data);
              if (msg.type === "frigateReady") {
                if (readyTimerRef.current) clearTimeout(readyTimerRef.current);
                if (skipTimerRef.current) clearTimeout(skipTimerRef.current);
                setShowSkip(false);
                setLoading(false);
              }
            } catch {}
          }}
          onError={() => {
            if (readyTimerRef.current) clearTimeout(readyTimerRef.current);
            if (skipTimerRef.current) clearTimeout(skipTimerRef.current);
            setLoading(false);
            setShowSkip(false);
            setServerStatus("offline");
          }}
          onHttpError={(e) => {
            if (e.nativeEvent.statusCode === 401) setServerStatus("auth");
            else if (e.nativeEvent.statusCode >= 500) {
              if (readyTimerRef.current) clearTimeout(readyTimerRef.current);
              if (skipTimerRef.current) clearTimeout(skipTimerRef.current);
              setLoading(false);
              setShowSkip(false);
              setServerStatus("offline");
            }
          }}
        />
      </View>

      {/* No-network banner — thin strip at top, auto-dismisses when reconnected */}
      {isOffline && (
        <View style={{ position: "absolute", top: insets.top, left: 0, right: 0, backgroundColor: "#7f1d1d", paddingVertical: 6, alignItems: "center", flexDirection: "row", justifyContent: "center", gap: 6 }}>
          <Ionicons name="wifi-outline" size={13} color="#fca5a5" />
          <Text style={{ color: "#fca5a5", fontSize: 12, fontWeight: "600" }}>No internet connection</Text>
        </View>
      )}

      {/* Loading splash */}
      {loading && serverStatus !== "offline" && (
        <View style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center", padding: 24 }}>
          <View style={{ width: 64, height: 64, borderRadius: 18, backgroundColor: "#1e293b", alignItems: "center", justifyContent: "center", marginBottom: 16, shadowColor: "#00d4ff", shadowOpacity: 0.3, shadowRadius: 16, shadowOffset: { width: 0, height: 0 } }}>
            <Ionicons name="shield" size={32} color="#00d4ff" />
          </View>
          <ActivityIndicator color="#00d4ff" />
          <Text style={{ color: "#64748b", marginTop: 12, fontSize: 13, letterSpacing: 0.3 }}>Connecting to Frigate…</Text>

          {/* Escape hatch — appears after 6 s so the user is never trapped behind the splash. */}
          {showSkip && (
            <View style={{ marginTop: 32, alignItems: "center", gap: 12 }}>
              <Text style={{ color: "#475569", fontSize: 12, textAlign: "center", maxWidth: 280 }}>
                Taking longer than usual. Frigate may be slow to load, or the server URL might be wrong.
              </Text>
              <View style={{ flexDirection: "row", gap: 10 }}>
                <TouchableOpacity
                  onPress={() => { haptic.tap(); setLoading(false); setShowSkip(false); }}
                  style={{ backgroundColor: "#1e293b", borderColor: "#334155", borderWidth: 1, borderRadius: 12, paddingVertical: 11, paddingHorizontal: 18 }}
                >
                  <Text style={{ color: "#f1f5f9", fontWeight: "600", fontSize: 13 }}>Show app anyway</Text>
                </TouchableOpacity>
                <TouchableOpacity
                  onPress={() => { haptic.tap(); webviewRef.current?.reload(); }}
                  style={{ backgroundColor: "#00d4ff", borderRadius: 12, paddingVertical: 11, paddingHorizontal: 18 }}
                >
                  <Text style={{ color: "#0a0f1e", fontWeight: "700", fontSize: 13 }}>Retry</Text>
                </TouchableOpacity>
              </View>
              <TouchableOpacity
                onPress={() => { haptic.tap(); setSettingsOpen(true); }}
                style={{ paddingVertical: 6 }}
              >
                <Text style={{ color: "#64748b", fontSize: 12 }}>Open settings to change server URL</Text>
              </TouchableOpacity>
            </View>
          )}
        </View>
      )}

      {/* Connection error overlay — shows when server is unreachable, includes inline URL fixer */}
      {serverStatus === "offline" && (
        <View style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, backgroundColor: "#0a0f1e", alignItems: "center", justifyContent: "center", padding: 28 }}>
          <View style={{ width: 64, height: 64, borderRadius: 18, backgroundColor: "#1e293b", alignItems: "center", justifyContent: "center", marginBottom: 16 }}>
            <Ionicons name="cloud-offline-outline" size={32} color="#ef4444" />
          </View>
          <Text style={{ color: "#f1f5f9", fontSize: 18, fontWeight: "700", marginBottom: 6 }}>Can't reach Frigate</Text>
          <Text style={{ color: "#64748b", fontSize: 13, textAlign: "center", marginBottom: 4 }}>
            {baseUrl.replace(/^https?:\/\//, "")}
          </Text>
          <Text style={{ color: "#475569", fontSize: 12, textAlign: "center", marginBottom: 28, maxWidth: 280 }}>
            Make sure your phone can reach this server via Wi-Fi, VPN, or Tailscale.
          </Text>

          {/* Inline URL fixer */}
          <View style={{ width: "100%", maxWidth: 340, marginBottom: 16 }}>
            <Text style={{ color: "#64748b", fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.5, marginBottom: 8 }}>
              Wrong URL? Change it here
            </Text>
            <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#1e293b", borderRadius: 12, paddingHorizontal: 14, borderWidth: 1, borderColor: "#334155", gap: 10 }}>
              <Ionicons name="globe-outline" size={16} color="#475569" />
              <TextInput
                style={{ flex: 1, paddingVertical: 13, color: "#f1f5f9", fontSize: 14 }}
                placeholder={baseUrl || "https://your-frigate-host.com"}
                placeholderTextColor="#475569"
                value={errorUrlDraft}
                onChangeText={setErrorUrlDraft}
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="url"
              />
            </View>
            {errorUrlDraft.startsWith("http") && (
              <TouchableOpacity
                onPress={async () => {
                  haptic.tap();
                  const clean = errorUrlDraft.trim().replace(/\/$/, "");
                  await setBaseUrl(clean);
                  setErrorUrlDraft("");
                  setServerStatus("unknown");
                  setLoading(true);
                  setTimeout(() => webviewRef.current?.reload(), 300);
                }}
                style={{ backgroundColor: "#00d4ff", borderRadius: 12, paddingVertical: 12, alignItems: "center", marginTop: 10 }}
              >
                <Text style={{ color: "#0a0f1e", fontWeight: "700" }}>Save & Connect</Text>
              </TouchableOpacity>
            )}
          </View>

          <TouchableOpacity
            onPress={() => { haptic.tap(); setServerStatus("unknown"); setLoading(true); setTimeout(() => webviewRef.current?.reload(), 100); }}
            style={{ flexDirection: "row", alignItems: "center", gap: 6, paddingVertical: 10 }}
          >
            <Ionicons name="refresh" size={15} color="#475569" />
            <Text style={{ color: "#475569", fontSize: 13 }}>Retry without changing URL</Text>
          </TouchableOpacity>
        </View>
      )}

      {/* Camera quick-switch button — hidden in landscape for immersive viewing */}
      {cameras.length > 0 && !isLandscape && (
        <TouchableOpacity
          onPress={() => { haptic.tap(); setCameraMenuOpen(true); }}
          style={{
            position: "absolute",
            bottom: insets.bottom + 126,
            right: 14,
            width: 36,
            height: 36,
            borderRadius: 18,
            backgroundColor: "#0f172aee",
            borderWidth: 1,
            borderColor: "#1e293b",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <Ionicons name="videocam-outline" size={16} color="#64748b" />
        </TouchableOpacity>
      )}

      {/* Floating gear button — hidden in landscape for immersive viewing */}
      {!isLandscape && (
        <TouchableOpacity
          onPress={() => { haptic.tap(); setSettingsOpen(true); }}
          style={{
            position: "absolute",
            bottom: insets.bottom + 82,
            right: 14,
            width: 36,
            height: 36,
            borderRadius: 18,
            backgroundColor: "#0f172aee",
            borderWidth: 1,
            borderColor: "#1e293b",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <Ionicons name="settings-outline" size={16} color="#64748b" />
        </TouchableOpacity>
      )}

      {/* Motion alert toast — slides in from top, auto-dismisses after 4s */}
      {toastMsg && (
        <Animated.View
          style={{
            position: "absolute",
            top: insets.top + 10,
            left: 16,
            right: 16,
            transform: [{ translateY: toastAnim }],
            backgroundColor: "#0f172aee",
            borderRadius: 14,
            paddingVertical: 12,
            paddingHorizontal: 16,
            flexDirection: "row",
            alignItems: "center",
            gap: 10,
            borderWidth: 1,
            borderColor: "#1e293b",
            shadowColor: "#000",
            shadowOpacity: 0.5,
            shadowRadius: 12,
            shadowOffset: { width: 0, height: 4 },
          }}
        >
          <View style={{ width: 32, height: 32, borderRadius: 8, backgroundColor: "#ef444420", alignItems: "center", justifyContent: "center" }}>
            <Ionicons name="alert-circle" size={18} color="#ef4444" />
          </View>
          <Text style={{ flex: 1, color: "#f1f5f9", fontSize: 14, fontWeight: "600" }} numberOfLines={1}>
            {toastMsg}
          </Text>
        </Animated.View>
      )}

      {/* ── Camera quick-switch modal ──────────────────────────────────────── */}
      <Modal
        visible={cameraMenuOpen}
        transparent
        animationType="slide"
        onRequestClose={() => setCameraMenuOpen(false)}
      >
        <TouchableOpacity
          style={{ flex: 1, backgroundColor: "#00000099" }}
          activeOpacity={1}
          onPress={() => setCameraMenuOpen(false)}
        />
        <SafeAreaView style={{ backgroundColor: "#0a0f1e" }} edges={["bottom"]}>
          <View style={{ backgroundColor: "#0a0f1e", borderTopLeftRadius: 24, borderTopRightRadius: 24, borderTopWidth: 1, borderColor: "#1e293b" }}>
            <View style={{ alignItems: "center", paddingTop: 12, paddingBottom: 16, paddingHorizontal: 20 }}>
              <View style={{ width: 40, height: 4, borderRadius: 2, backgroundColor: "#334155", marginBottom: 16 }} />
              <View style={{ flexDirection: "row", alignItems: "center", gap: 8, alignSelf: "flex-start" }}>
                <View style={{ width: 28, height: 28, borderRadius: 7, backgroundColor: "#10b98122", alignItems: "center", justifyContent: "center" }}>
                  <Ionicons name="videocam" size={14} color="#10b981" />
                </View>
                <Text style={{ color: "#f1f5f9", fontSize: 17, fontWeight: "700" }}>Cameras</Text>
                <Text style={{ color: "#475569", fontSize: 13 }}>({cameras.length})</Text>
              </View>
            </View>
            <ScrollView
              style={{ paddingHorizontal: 16, maxHeight: 320 }}
              contentContainerStyle={{ paddingBottom: 24, gap: 8 }}
              showsVerticalScrollIndicator={false}
            >
              {cameras.map((cam) => (
                <TouchableOpacity
                  key={cam}
                  onPress={() => handleCameraSelect(cam)}
                  style={{
                    flexDirection: "row", alignItems: "center", gap: 12,
                    backgroundColor: "#1e293b", borderRadius: 12, padding: 14,
                  }}
                  activeOpacity={0.7}
                >
                  <View style={{ width: 32, height: 32, borderRadius: 8, backgroundColor: "#10b98122", alignItems: "center", justifyContent: "center" }}>
                    <Ionicons name="videocam-outline" size={16} color="#10b981" />
                  </View>
                  <Text style={{ flex: 1, color: "#f1f5f9", fontSize: 15, fontWeight: "500", textTransform: "capitalize" }}>
                    {cam.replace(/_/g, " ")}
                  </Text>
                  <Ionicons name="chevron-forward" size={16} color="#334155" />
                </TouchableOpacity>
              ))}
            </ScrollView>
          </View>
        </SafeAreaView>
      </Modal>

      {/* ── Settings bottom sheet ──────────────────────────────────────────── */}
      <Modal
        visible={settingsOpen}
        transparent
        animationType="slide"
        onRequestClose={dismissSettings}
      >
        {/* Tap outside to dismiss */}
        <TouchableOpacity
          style={{ flex: 1, backgroundColor: "#00000099" }}
          activeOpacity={1}
          onPress={dismissSettings}
        />

        <SafeAreaView style={{ backgroundColor: "#0a0f1e" }} edges={["bottom"]}>
          <View style={{ backgroundColor: "#0a0f1e", borderTopLeftRadius: 24, borderTopRightRadius: 24, borderTopWidth: 1, borderColor: "#1e293b", maxHeight: "86%" }}>

            {/* Drag handle — swipe down here to dismiss */}
            <View
              {...handlePan.panHandlers}
              style={{ alignItems: "center", paddingTop: 12, paddingBottom: 8, paddingHorizontal: 20 }}
            >
              <View style={{ width: 40, height: 4, borderRadius: 2, backgroundColor: "#334155", marginBottom: 14 }} />
              <View style={{ flexDirection: "row", alignItems: "center", gap: 8, alignSelf: "flex-start" }}>
                <View style={{ width: 28, height: 28, borderRadius: 7, backgroundColor: "#00d4ff22", alignItems: "center", justifyContent: "center" }}>
                  <Ionicons name="shield" size={15} color="#00d4ff" />
                </View>
                <Text style={{ color: "#f1f5f9", fontSize: 17, fontWeight: "700", letterSpacing: -0.3 }}>Apex</Text>
                {/* Live connection dot next to title */}
                <View style={{ flexDirection: "row", alignItems: "center", gap: 4, marginLeft: 4 }}>
                  <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: statusColor[serverStatus] }} />
                  <Text style={{ color: statusColor[serverStatus], fontSize: 11, fontWeight: "600" }}>
                    {statusLabel[serverStatus]}
                  </Text>
                </View>
              </View>
            </View>

            <ScrollView
              style={{ paddingHorizontal: 16 }}
              contentContainerStyle={{ paddingBottom: 32 }}
              showsVerticalScrollIndicator={false}
            >

              {/* ── ACCOUNT ────────────────────────────────────────── */}
              <SectionHeader title="Account" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, overflow: "hidden" }}>
                <View style={{ padding: 14 }}>
                  <Row
                    icon="person-circle-outline" iconColor="#a855f7" iconBg="#a855f722"
                    label={username ?? "Unknown"}
                    sub="Logged in to Frigate"
                    right={
                      !changingCreds ? (
                        <TouchableOpacity
                          onPress={() => { setUserDraft(username ?? ""); setPassDraft(""); setCredError(""); setChangingCreds(true); }}
                          style={{ backgroundColor: "#334155", borderRadius: 8, paddingHorizontal: 10, paddingVertical: 5 }}
                        >
                          <Text style={{ color: "#94a3b8", fontSize: 12, fontWeight: "600" }}>Change</Text>
                        </TouchableOpacity>
                      ) : null
                    }
                  />
                </View>

                {changingCreds && (
                  <>
                    <View style={{ height: 1, backgroundColor: "#334155" }} />
                    <View style={{ padding: 14, gap: 10 }}>
                      <Text style={{ color: "#94a3b8", fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.5 }}>New Credentials</Text>
                      <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#0f172a", borderRadius: 10, paddingHorizontal: 12, gap: 8, borderWidth: 1, borderColor: "#334155" }}>
                        <Ionicons name="person-outline" size={15} color="#475569" />
                        <TextInput
                          style={{ flex: 1, paddingVertical: 11, color: "#f1f5f9", fontSize: 14 }}
                          placeholder="Username" placeholderTextColor="#475569"
                          value={userDraft} onChangeText={setUserDraft}
                          autoCapitalize="none" autoCorrect={false} textContentType="username"
                        />
                      </View>
                      <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#0f172a", borderRadius: 10, paddingHorizontal: 12, gap: 8, borderWidth: 1, borderColor: "#334155" }}>
                        <Ionicons name="lock-closed-outline" size={15} color="#475569" />
                        <TextInput
                          style={{ flex: 1, paddingVertical: 11, color: "#f1f5f9", fontSize: 14 }}
                          placeholder="Password" placeholderTextColor="#475569"
                          value={passDraft} onChangeText={setPassDraft}
                          secureTextEntry={!showPass} textContentType="password"
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
                          onPress={handleSaveCreds} disabled={credLoading}
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

              {/* ── SERVER ─────────────────────────────────────────── */}
              <SectionHeader title="Server" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, overflow: "hidden" }}>
                {editingUrl ? (
                  <View style={{ padding: 14, gap: 10 }}>
                    <TextInput
                      style={{ color: "#f1f5f9", fontSize: 14, backgroundColor: "#0f172a", borderRadius: 10, padding: 12, borderWidth: 1, borderColor: "#334155" }}
                      value={urlDraft} onChangeText={setUrlDraft}
                      autoCapitalize="none" autoCorrect={false} keyboardType="url"
                      placeholder="https://your-frigate-host.com" placeholderTextColor="#475569"
                    />
                    <View style={{ flexDirection: "row", gap: 8 }}>
                      <TouchableOpacity onPress={() => setEditingUrl(false)} style={{ flex: 1, backgroundColor: "#334155", borderRadius: 10, paddingVertical: 11, alignItems: "center" }}>
                        <Text style={{ color: "#94a3b8", fontWeight: "600" }}>Cancel</Text>
                      </TouchableOpacity>
                      <TouchableOpacity onPress={handleSaveUrl} style={{ flex: 2, backgroundColor: "#00d4ff", borderRadius: 10, paddingVertical: 11, alignItems: "center" }}>
                        <Text style={{ color: "#0a0f1e", fontWeight: "700" }}>Save & Reload</Text>
                      </TouchableOpacity>
                    </View>
                  </View>
                ) : (
                  <View style={{ padding: 14 }}>
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
                  </View>
                )}
              </View>

              {/* ── HOME ASSISTANT DEEP LINKS ──────────────────────── */}
              <SectionHeader title="Home Assistant Deep Links" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14, gap: 10 }}>
                <Text style={{ color: "#64748b", fontSize: 12, lineHeight: 17 }}>
                  Add <Text style={{ color: "#94a3b8", fontFamily: "monospace" }}>url: "apex://..."</Text> to your HA notification action. Tap any URL to share/copy it.
                </Text>
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                {DEEP_LINKS.map(({ route, desc, example }) => (
                  <TouchableOpacity
                    key={route}
                    onPress={() => handleShare(example)}
                    style={{ flexDirection: "row", alignItems: "center", gap: 10, paddingVertical: 4 }}
                    activeOpacity={0.6}
                  >
                    <View style={{ flex: 1 }}>
                      <Text style={{ color: "#00d4ff", fontSize: 13, fontFamily: "monospace", marginBottom: 2 }}>
                        apex://{route}
                      </Text>
                      <Text style={{ color: "#475569", fontSize: 11 }}>{desc}</Text>
                    </View>
                    <Ionicons name="share-outline" size={15} color="#334155" />
                  </TouchableOpacity>
                ))}
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                {/* HA YAML example block */}
                <View style={{ backgroundColor: "#0f172a", borderRadius: 10, padding: 12 }}>
                  <Text style={{ color: "#475569", fontSize: 10, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.5, marginBottom: 6 }}>Example HA Action</Text>
                  <Text style={{ color: "#64748b", fontSize: 12, fontFamily: "monospace", lineHeight: 20 }}>
                    <Text style={{ color: "#94a3b8" }}>action</Text>
                    <Text style={{ color: "#64748b" }}>: notify.mobile_app_iphone{"\n"}</Text>
                    <Text style={{ color: "#94a3b8" }}>data</Text>
                    <Text style={{ color: "#64748b" }}>:{"\n"}</Text>
                    <Text style={{ color: "#64748b" }}>{"  "}</Text>
                    <Text style={{ color: "#94a3b8" }}>message</Text>
                    <Text style={{ color: "#64748b" }}>: Person detected{"\n"}</Text>
                    <Text style={{ color: "#64748b" }}>{"  "}</Text>
                    <Text style={{ color: "#94a3b8" }}>data</Text>
                    <Text style={{ color: "#64748b" }}>:{"\n"}</Text>
                    <Text style={{ color: "#64748b" }}>{"    "}</Text>
                    <Text style={{ color: "#94a3b8" }}>url</Text>
                    <Text style={{ color: "#64748b" }}>: </Text>
                    <Text style={{ color: "#00d4ff" }}>"apex://cameras/driveway"</Text>
                  </Text>
                </View>
              </View>

              {/* ── NATIVE FEATURES ────────────────────────────────── */}
              <SectionHeader title="Native Features" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14, gap: 10 }}>
                <Row icon="phone-portrait-outline" iconColor="#10b981" iconBg="#10b98122"
                  label="Picture-in-Picture" sub="Auto-activates when you background the app" />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <Row icon="tv-outline" iconColor="#10b981" iconBg="#10b98122"
                  label="AirPlay" sub="Stream cameras to Apple TV via native controls" />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <Row icon="sunny-outline" iconColor="#10b981" iconBg="#10b98122"
                  label="Keep Screen On" sub="Display stays awake while Apex is open" />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <Row icon="swap-horizontal-outline" iconColor="#10b981" iconBg="#10b98122"
                  label="Back/Forward Swipe" sub="Swipe left/right to navigate Frigate history" />
                <View style={{ height: 1, backgroundColor: "#334155" }} />
                <Row icon="refresh-circle-outline" iconColor="#10b981" iconBg="#10b98122"
                  label="Shake to Reload" sub="Shake the phone to force-refresh Frigate" />
                {cameras.length > 0 && (
                  <>
                    <View style={{ height: 1, backgroundColor: "#334155" }} />
                    <Row icon="videocam-outline" iconColor="#10b981" iconBg="#10b98122"
                      label="Camera Switcher" sub={`Tap the camera button to jump between ${cameras.length} cameras`} />
                  </>
                )}
              </View>

              {/* ── ACTIONS ────────────────────────────────────────── */}
              <SectionHeader title="Actions" />
              <View style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}>
                <TouchableOpacity onPress={() => { haptic.tap(); webviewRef.current?.reload(); dismissSettings(); }}>
                  <Row icon="refresh-outline" iconColor="#a855f7" iconBg="#a855f722"
                    label="Reload Frigate" sub="Force refresh the web app" />
                </TouchableOpacity>
              </View>

              {/* ── SIGN OUT ───────────────────────────────────────── */}
              <View style={{ marginTop: 8, marginBottom: 4 }}>
                <TouchableOpacity onPress={handleLogout} style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}>
                  <Row icon="log-out-outline" iconColor="#ef4444" iconBg="#ef444422"
                    label="Sign Out" sub="Clears your session from this device" />
                </TouchableOpacity>
              </View>

              {/* ── VERSION ────────────────────────────────────────── */}
              <Text style={{ color: "#1e293b", fontSize: 11, textAlign: "center", marginTop: 12 }}>
                Apex v{appVersion} ({buildNumber})
              </Text>

            </ScrollView>
          </View>
        </SafeAreaView>
      </Modal>
    </View>
  );
}
