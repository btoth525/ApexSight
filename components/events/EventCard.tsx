import { TouchableOpacity, View, Text, Image } from "react-native";
import { FrigateEvent } from "@/types/event";
import { useAuthStore } from "@/stores/authStore";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";
import { formatRelativeTime } from "@/utils/timeUtil";

type EventCardProps = {
  event: FrigateEvent;
  onPress: () => void;
  size?: number;
};

export function EventCard({ event, onPress, size = 120 }: EventCardProps) {
  const { baseUrl } = useAuthStore();
  const thumbUrl = `${baseUrl}/api/events/${event.id}/thumbnail.webp`;

  return (
    <TouchableOpacity onPress={onPress} activeOpacity={0.8} style={{ width: size, marginBottom: 8 }}>
      <View style={{ width: size, height: size }} className="rounded-xl overflow-hidden bg-surface-2">
        <Image source={{ uri: thumbUrl }} style={{ width: size, height: size }} resizeMode="cover" />
        <View className="absolute bottom-0 left-0 right-0 bg-black/60 px-2 py-1">
          <Text className="text-white text-xs font-medium" numberOfLines={1}>
            {getLabelEmoji(event.label)} {formatLabel(event.label)}
          </Text>
        </View>
      </View>
      <Text className="text-text-secondary text-xs mt-1 text-center">
        {formatRelativeTime(event.start_time)}
      </Text>
    </TouchableOpacity>
  );
}
