import { useState } from "react";
import { TouchableOpacity, View, Text, Image, ActivityIndicator, Dimensions } from "react-native";
import { useAuthStore } from "@/stores/authStore";

type CameraCardProps = {
  name: string;
  displayName?: string;
  onPress: () => void;
  width?: number;
};

const { width: SCREEN_WIDTH } = Dimensions.get("window");

export function CameraCard({ name, displayName, onPress, width }: CameraCardProps) {
  const { baseUrl } = useAuthStore();
  const [imgError, setImgError] = useState(false);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(Date.now());

  // Refresh every 2 seconds via cache-busting query param
  // Use a simple interval approach: the image src changes every 2s
  const cardWidth = width ?? (SCREEN_WIDTH - 48) / 2;
  const cardHeight = cardWidth * 0.5625; // 16:9

  const snapUrl = `${baseUrl}/api/${name}/latest.jpg?t=${tick}`;

  // Refresh on mount and every 2s
  useState(() => {
    const interval = setInterval(() => setTick(Date.now()), 2000);
    return () => clearInterval(interval);
  });

  return (
    <TouchableOpacity
      onPress={onPress}
      className="rounded-xl overflow-hidden bg-surface border border-border"
      style={{ width: cardWidth, height: cardHeight + 36 }}
      activeOpacity={0.85}
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
          <View className="flex-1 items-center justify-center">
            <Image
              source={require("@/assets/icon.png")}
              style={{ width: 48, height: 48, borderRadius: 10, opacity: 0.6 }}
              resizeMode="cover"
            />
          </View>
        )}
        {loading && !imgError && (
          <View className="absolute inset-0 items-center justify-center">
            <ActivityIndicator color="#00b4d8" size="small" />
          </View>
        )}
        {/* Live dot */}
        <View className="absolute top-2 left-2 flex-row items-center bg-black/60 rounded-full px-2 py-0.5 gap-1">
          <View className="w-1.5 h-1.5 rounded-full bg-red-500" />
          <Text className="text-white text-xs font-medium">LIVE</Text>
        </View>
      </View>
      <View className="px-2 py-1.5 flex-row items-center justify-between">
        <Text className="text-text-primary text-sm font-medium flex-1" numberOfLines={1}>
          {displayName ?? name}
        </Text>
      </View>
    </TouchableOpacity>
  );
}
