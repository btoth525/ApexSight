import { TouchableOpacity, View, Text, Image } from "react-native";
import { ReviewItem } from "@/types/event";
import { useAuthStore } from "@/stores/authStore";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";
import { formatRelativeTime, formatDuration } from "@/utils/timeUtil";

type ReviewCardProps = {
  item: ReviewItem;
  onPress: () => void;
};

export function ReviewCard({ item, onPress }: ReviewCardProps) {
  const { baseUrl } = useAuthStore();
  const label = item.data?.objects?.[0] ?? "motion";
  const duration = item.end_time ? item.end_time - item.start_time : null;
  const thumbUrl = item.data?.detections?.[0]
    ? `${baseUrl}/api/events/${item.data.detections[0]}/thumbnail.webp`
    : null;

  return (
    <TouchableOpacity
      onPress={onPress}
      className={`flex-row items-center bg-surface rounded-xl p-3 mb-2 mx-4 border ${item.has_been_reviewed ? "border-border opacity-60" : "border-border"}`}
      activeOpacity={0.8}
    >
      {/* Thumbnail */}
      <View className="w-16 h-12 rounded-lg overflow-hidden bg-surface-2 mr-3">
        {thumbUrl ? (
          <Image source={{ uri: thumbUrl }} className="w-full h-full" resizeMode="cover" />
        ) : (
          <View className="flex-1 items-center justify-center">
            <Text className="text-2xl">{getLabelEmoji(label)}</Text>
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
