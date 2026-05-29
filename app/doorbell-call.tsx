import { useEffect, useRef } from "react";
import { View, Text, TouchableOpacity } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";
import { WebView } from "react-native-webview";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { useAuthStore } from "@/stores/authStore";
import * as Haptics from "expo-haptics";

// Auto-clicks go2rtc's play/connect button after the page loads.
// go2rtc web UI renders a single play button; we target it with a MutationObserver fallback.
const GO2RTC_AUTOPLAY_JS = `
(function() {
  function tryConnect() {
    var btn = document.querySelector('button.play, button[title="play"], button[type="button"], button');
    if (btn) { btn.click(); return true; }
    return false;
  }
  if (!tryConnect()) {
    var obs = new MutationObserver(function() {
      if (tryConnect()) obs.disconnect();
    });
    obs.observe(document.body, { childList: true, subtree: true });
    setTimeout(function() { obs.disconnect(); }, 10000);
  }
})();
true;
`;

export default function DoorbellCallScreen() {
  const { camera } = useLocalSearchParams<{ camera: string }>();
  const { baseUrl, token, isLoading } = useAuthStore();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const webViewRef = useRef<WebView>(null);

  const cameraName = camera ?? "doorbell";

  // go2rtc WebRTC player — Frigate proxies go2rtc at /api/go2rtc/
  const streamUrl = `${baseUrl}/api/go2rtc/webrtc?src=${encodeURIComponent(cameraName)}`;

  useEffect(() => {
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
  }, []);

  const handleEndCall = () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
    router.back();
  };

  return (
    <View style={{ flex: 1, backgroundColor: "#000000" }}>
      {/* go2rtc WebRTC stream — two-way audio via mediaCapturePermissionGrantType */}
      {!isLoading && (
        <WebView
          ref={webViewRef}
          source={{
            uri: streamUrl,
            headers: token ? { Authorization: `Bearer ${token}` } : undefined,
          }}
          style={{ flex: 1, backgroundColor: "#000000" }}
          allowsInlineMediaPlayback={true}
          mediaPlaybackRequiresUserAction={false}
          allowsAirPlayForMediaPlayback={false}
          sharedCookiesEnabled={true}
          originWhitelist={["*"]}
          injectedJavaScript={GO2RTC_AUTOPLAY_JS}
          // Auto-grant mic permission for same-host WebRTC (two-way audio)
          // NSMicrophoneUsageDescription already present in app.json
          mediaCapturePermissionGrantType="grantIfSameHostElseDeny"
        />
      )}

      {/* Caller pill — top overlay */}
      <View
        style={{
          position: "absolute",
          top: insets.top + 12,
          left: 0,
          right: 0,
          alignItems: "center",
          pointerEvents: "none",
        }}
      >
        <View
          style={{
            backgroundColor: "rgba(0,0,0,0.6)",
            borderRadius: 22,
            paddingHorizontal: 20,
            paddingVertical: 8,
            alignItems: "center",
          }}
        >
          <Text style={{ color: "#ffffff", fontSize: 15, fontWeight: "600" }}>
            Front Door
          </Text>
          <Text style={{ color: "rgba(255,255,255,0.55)", fontSize: 12, marginTop: 2 }}>
            Live
          </Text>
        </View>
      </View>

      {/* End Call button — bottom center */}
      <View
        style={{
          position: "absolute",
          bottom: insets.bottom + 44,
          left: 0,
          right: 0,
          alignItems: "center",
        }}
      >
        <TouchableOpacity
          onPress={handleEndCall}
          activeOpacity={0.8}
          style={{
            width: 72,
            height: 72,
            borderRadius: 36,
            backgroundColor: "#ef4444",
            alignItems: "center",
            justifyContent: "center",
            shadowColor: "#ef4444",
            shadowOpacity: 0.5,
            shadowRadius: 16,
            shadowOffset: { width: 0, height: 4 },
          }}
        >
          <Ionicons
            name="call"
            size={30}
            color="#ffffff"
            style={{ transform: [{ rotate: "135deg" }] }}
          />
        </TouchableOpacity>
        <Text
          style={{
            color: "rgba(255,255,255,0.45)",
            fontSize: 12,
            marginTop: 8,
            fontWeight: "500",
          }}
        >
          End Call
        </Text>
      </View>
    </View>
  );
}
