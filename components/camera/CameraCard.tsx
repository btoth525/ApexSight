import { useState, useEffect, useCallback } from "react";
import { Pressable, View, Text, Image, ActivityIndicator, Dimensions, ActionSheetIOS, Platform, Alert, Share } from "react-native";
import { useAuthStore } from "@/stores/authStore";
import { haptic } from "@/utils/haptics";

type CameraCardProps = {
  name: string;
  displayName?: string;
  onPress: () => void;
  onViewEvents?: (camera: string) => void;
  width?: number;
};

const { width: SCREEN_WIDTH } = Dimensions.get("window");

export function CameraCard({ name, displayName, onPress, onViewEvents, width }: CameraCardProps) {
  const { baseUrl } = useAuthStore();
  const [imgError, setImgError] = useState(false);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(Date.now());

  const cardWidth = width ?? (SCREEN_WIDTH - 48) / 2;
  const cardHeight = cardWidth * 0.5625;
  const snapUrl = `${baseUrl}/api/${name}/latest.jpg?t=${tick}`;

  useEffect(() => {
    const interval = setInterval(() => setTick(Date.now()), 2000);
    return () => clearInterval(interval);
  }, []);

  const handleLongPress = useCallback(() => {
    haptic.heavy();
    const streamUrl = `${baseUrl}/api/${name}/stream.m3u8`;
    const options = ["Go Live", "View Recent Events", "Copy Stream URL", "Cancel"];
    if (Platform.OS === "ios") {
      ActionSheetIOS.showActionSheetWithOptions(
        { options, cancelButtonIndex: 3, title: displayName ?? name },
        (index) => {
          if (index === 0) { haptic.tap(); onPress(); }
          else if (index === 1) { haptic.tap(); onViewEvents?.(name); }
          else if (index === 2) {
            haptic.success();
            Share.share({ message: streamUrl, url: streamUrl });
          }
        }
      );
    } else {
      Alert.alert(displayName ?? name, undefined, [
        { text: "Go Live", onPress: () => { haptic.tap(); onPress(); } },
        { text: "View Events", onPress: () => { haptic.tap(); onViewEvents?.(name); } },
        { text: "Cancel", style: "cancel" },
      ]);
    }
  }, [name, displayName, baseUrl, onPress, onViewEvents]);

  return (
    <Pressable
      onPress={() => { haptic.tap(); onPress(); }}
      onLongPress={handleLongPress}
      delayLongPress={400}
      style={{ width: cardWidth, height: cardHeight + 36, borderRadius: 12, overflow: "hidden", backgroundColor: "#1e293b", borderWidth: 1, borderColor: "#334155" }}
    >
      <View style={{ width: cardWidth, height: cardHeight, backgroundColor: "#0f172a" }}>
        {!imgError ? (
          <Image
            source={{ uri: snapUrl }}
            style={{ width: cardWidth, height: cardHeight }}
            resizeMode="cover"
            onLoadStart={() => setLoading(true)}
            onLoad={() => setLoading(false)}
            onError={() => { setImgError(true); setLoading(false); }}
          />
        ) : (
          <View style={{ flex: 1, alignItems: "center", justifyContent: "center" }}>
            <Image
              source={require("@/assets/icon.png")}
              style={{ width: 48, height: 48, borderRadius: 10, opacity: 0.6 }}
              resizeMode="cover"
            />
          </View>
        )}
        {loading && !imgError && (
          <View style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, alignItems: "center", justifyContent: "center" }}>
            <ActivityIndicator color="#00b4d8" size="small" />
          </View>
        )}
        {/* Live badge */}
        <View style={{ position: "absolute", top: 8, left: 8, flexDirection: "row", alignItems: "center", backgroundColor: "rgba(0,0,0,0.6)", borderRadius: 99, paddingHorizontal: 8, paddingVertical: 2, gap: 4 }}>
          <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: "#ef4444" }} />
          <Text style={{ color: "#fff", fontSize: 10, fontWeight: "600" }}>LIVE</Text>
        </View>
        {/* Long-press hint */}
        <View style={{ position: "absolute", top: 8, right: 8 }}>
          <Text style={{ color: "rgba(255,255,255,0.4)", fontSize: 14 }}>⋯</Text>
        </View>
      </View>
      <View style={{ paddingHorizontal: 8, paddingVertical: 6 }}>
        <Text style={{ color: "#f1f5f9", fontSize: 13, fontWeight: "500" }} numberOfLines={1}>
          {displayName ?? name}
        </Text>
      </View>
    </Pressable>
  );
}
