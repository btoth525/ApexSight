import { useEffect, useMemo, useRef } from "react";
import { View, Text, TouchableOpacity } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";
import { WebView } from "react-native-webview";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { useAuthStore } from "@/stores/authStore";
import * as Haptics from "expo-haptics";

// Minimal WebRTC client that talks directly to go2rtc's WebSocket signaling API.
// This bypasses Frigate's go2rtc web-interface route (which requires admin role)
// and instead uses go2rtc's /api/ws endpoint which is accessible with a valid token.
function buildWebRTCHtml(wsUrl: string): string {
  return `<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body { background:#000; width:100vw; height:100vh; overflow:hidden; }
video { width:100%; height:100%; object-fit:cover; display:block; }
</style>
</head>
<body>
<video id="v" autoplay playsinline></video>
<script>
(function() {
  var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
  var ws = new WebSocket(${JSON.stringify(wsUrl)});
  pc.ontrack = function(e) {
    var v = document.getElementById('v');
    if (!v.srcObject || v.srcObject !== e.streams[0]) v.srcObject = e.streams[0];
  };
  ws.onmessage = function(e) {
    try {
      var msg = JSON.parse(e.data);
      if (msg.type === 'offer') {
        pc.setRemoteDescription(new RTCSessionDescription(msg))
          .then(function() { return pc.createAnswer(); })
          .then(function(a) { pc.setLocalDescription(a); return a; })
          .then(function(a) { ws.send(JSON.stringify(a)); });
      } else if (msg.type === 'candidate' && msg.candidate) {
        pc.addIceCandidate(new RTCIceCandidate(msg.candidate)).catch(function(){});
      }
    } catch(err) {}
  };
  pc.onicecandidate = function(e) {
    if (e.candidate && ws.readyState === 1) {
      ws.send(JSON.stringify({ type: 'candidate', candidate: e.candidate }));
    }
  };
  ws.onopen = function() {
    try {
      pc.addTransceiver('video', { direction: 'recvonly' });
      pc.addTransceiver('audio', { direction: 'sendrecv' });
      pc.createOffer()
        .then(function(o) { pc.setLocalDescription(o); return o; })
        .then(function(o) { ws.send(JSON.stringify(o)); });
    } catch(err) {}
  };
})();
</script>
</body>
</html>`;
}

export default function DoorbellCallScreen() {
  const { camera } = useLocalSearchParams<{ camera: string }>();
  const { baseUrl, token, isLoading } = useAuthStore();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const webViewRef = useRef<WebView>(null);

  const cameraName = camera ?? "doorbell_twoway";

  // Build the go2rtc WebSocket signaling URL with the auth token as a query param.
  // Frigate's go2rtc proxy lives at /api/go2rtc/ and accepts ?token= for auth.
  const wsUrl = useMemo(() => {
    if (!baseUrl) return "";
    try {
      const url = new URL(baseUrl);
      const proto = url.protocol === "https:" ? "wss:" : "ws:";
      const tokenParam = token ? `&token=${encodeURIComponent(token)}` : "";
      return `${proto}//${url.host}/api/go2rtc/api/ws?src=${encodeURIComponent(cameraName)}${tokenParam}`;
    } catch {
      return "";
    }
  }, [baseUrl, token, cameraName]);

  const webRTCHtml = useMemo(() => buildWebRTCHtml(wsUrl), [wsUrl]);

  useEffect(() => {
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
  }, []);

  const handleEndCall = () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
    router.back();
  };

  return (
    <View style={{ flex: 1, backgroundColor: "#000000" }}>
      {/* Inject our own WebRTC HTML so we talk directly to go2rtc's WS API,
          bypassing Frigate's go2rtc web-interface page (admin-only 403). */}
      {!isLoading && wsUrl ? (
        <WebView
          ref={webViewRef}
          source={{ html: webRTCHtml, baseUrl }}
          style={{ flex: 1, backgroundColor: "#000000" }}
          allowsInlineMediaPlayback={true}
          mediaPlaybackRequiresUserAction={false}
          allowsAirPlayForMediaPlayback={false}
          sharedCookiesEnabled={true}
          originWhitelist={["*"]}
          mediaCapturePermissionGrantType="grantIfSameHostElseDeny"
        />
      ) : null}

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
