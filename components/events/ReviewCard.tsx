import { useState } from "react";
import { TouchableOpacity, View, Text, Image } from "react-native";
import { VideoView, useVideoPlayer } from "expo-video";
import { ReviewItem } from "@/types/event";
import { useAuthStore } from "@/stores/authStore";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";
import { formatRelativeTime, formatDuration } from "@/utils/timeUtil";
import { haptic } from "@/utils/haptics";

type ReviewCardProps = {
  item: ReviewItem;
  onPress: () => void;
};

function ClipPreview({ clipUrl, thumbUrl, label }: { clipUrl: string; thumbUrl: string | null; label: string }) {
  const [playing, setPlaying] = useState(false);
  const player = useVideoPlayer(clipUrl, (p) => { p.loop = true; p.muted = true; });

  const toggle = () => {
    haptic.tap();
    if (playing) { player.pause(); setPlaying(false); }
    else { player.play(); setPlaying(true); }
  };

  return (
    <TouchableOpacity onPress={toggle} activeOpacity={0.9}
      style={{ width: 72, height: 54, borderRadius: 10, overflow: "hidden", backgroundColor: "#0f172a" }}>
      {playing ? (
        <VideoView player={player} style={{ width: 72, height: 54 }} contentFit="cover" nativeControls={false} />
      ) : thumbUrl ? (
        <Image source={{ uri: thumbUrl }} style={{ width: 72, height: 54 }} resizeMode="cover" />
      ) : (
        <View style={{ flex: 1, alignItems: "center", justifyContent: "center" }}>
          <Text style={{ fontSize: 24 }}>{getLabelEmoji(label)}</Text>
        </View>
      )}
      {!playing && (
        <View style={{ position: "absolute", inset: 0, alignItems: "center", justifyContent: "center" }}>
          <View style={{ width: 22, height: 22, borderRadius: 11, backgroundColor: "rgba(0,0,0,0.65)", alignItems: "center", justifyContent: "center" }}>
            <Text style={{ fontSize: 9, color: "#fff", marginLeft: 2 }}>▶</Text>
          </View>
        </View>
      )}
    </TouchableOpacity>
  );
}

export function ReviewCard({ item, onPress }: ReviewCardProps) {
  const { baseUrl } = useAuthStore();
  const label = item.data?.objects?.[0] ?? "motion";
  const duration = item.end_time ? item.end_time - item.start_time : null;
  const eventId = item.data?.detections?.[0];
  const thumbUrl = eventId ? `${baseUrl}/api/events/${eventId}/thumbnail.webp` : null;
  const clipUrl = eventId ? `${baseUrl}/api/events/${eventId}/clip.mp4` : null;

  return (
    <TouchableOpacity
      onPress={() => { haptic.tap(); onPress(); }}
      className={`flex-row items-center bg-surface rounded-xl p-3 mb-2 mx-4 border ${item.has_been_reviewed ? "border-border opacity-60" : "border-border"}`}
      activeOpacity={0.8}
    >
      {/* Tap to preview clip inline, hold full card to open detail */}
      <View className="mr-3">
        {clipUrl ? (
          <ClipPreview clipUrl={clipUrl} thumbUrl={thumbUrl} label={label} />
        ) : (
          <View style={{ width: 72, height: 54, borderRadius: 10, overflow: "hidden", backgroundColor: "#1e293b", alignItems: "center", justifyContent: "center" }}>
            <Text style={{ fontSize: 24 }}>{getLabelEmoji(label)}</Text>
          </View>
        )}
      </View>

      {/* Info */}
      <View className="flex-1">
        <View className="flex-row items-center gap-2 mb-0.5">
          <Text className="text-text-primary font-semibold">{formatLabel(label)}</Text>
          <View className={`px-1.5 py-0.5 rounded-full ${item.severity === "alert" ? "bg-red-500/20" : "bg-yellow-500/20"}`}>
            <Text className={`text-xs ${item.severity === "alert" ? "text-red-400" : "text-yellow-400"}`}>
              {item.severity}
            </Text>
          </View>
        </View>
        <Text className="text-text-secondary text-sm">📷 {item.camera}</Text>
        {item.data?.zones?.length > 0 && (
          <Text className="text-text-secondary text-xs">📍 {item.data.zones.join(", ")}</Text>
        )}
      </View>

      {/* Time */}
      <View className="items-end">
        <Text className="text-text-secondary text-xs">{formatRelativeTime(item.start_time)}</Text>
        {duration !== null && (
          <Text className="text-text-secondary text-xs mt-1">{formatDuration(duration)}</Text>
        )}
        {item.has_been_reviewed && (
          <Text className="text-success text-xs mt-1">✓ reviewed</Text>
        )}
      </View>
    </TouchableOpacity>
  );
}
