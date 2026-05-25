import { View, Text, ScrollView, Image, TouchableOpacity, Dimensions } from "react-native";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { useAuthStore } from "@/stores/authStore";
import { AIInsights } from "@/types/api";
import { Skeleton } from "@/components/ui/Skeleton";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";
import { formatRelativeTime } from "@/utils/timeUtil";

const { width: SCREEN_WIDTH } = Dimensions.get("window");

type InsightsTabProps = {
  onEventPress: (eventId: string) => void;
};

export function InsightsTab({ onEventPress }: InsightsTabProps) {
  const { baseUrl } = useAuthStore();
  const { data: insights, isLoading } = useFrigateApi<AIInsights>("/ai/insights");

  if (isLoading) {
    return (
      <ScrollView className="flex-1" contentContainerStyle={{ padding: 16, gap: 16 }}>
        <Skeleton height={100} borderRadius={16} />
        <Skeleton height={200} borderRadius={16} />
        <Skeleton height={150} borderRadius={16} />
      </ScrollView>
    );
  }

  if (!insights) {
    return (
      <View className="flex-1 items-center justify-center">
        <Text className="text-4xl mb-4">🤖</Text>
        <Text className="text-text-primary text-lg">No insights available</Text>
        <Text className="text-text-secondary text-sm mt-2">Check your AI configuration</Text>
      </View>
    );
  }

  return (
    <ScrollView className="flex-1" contentContainerStyle={{ paddingBottom: 24 }}>
      {/* Hero Stats */}
      <View className="flex-row mx-4 mt-4 gap-3">
        <View className="flex-1 bg-surface rounded-2xl p-4 items-center">
          <Text className="text-3xl font-bold text-primary">{insights.stats?.total_events_today ?? 0}</Text>
          <Text className="text-text-secondary text-xs mt-1">Today</Text>
        </View>
        <View className="flex-1 bg-surface rounded-2xl p-4 items-center">
          <Text className="text-3xl font-bold text-primary">{insights.stats?.total_events_week ?? 0}</Text>
          <Text className="text-text-secondary text-xs mt-1">This Week</Text>
        </View>
        <View className="flex-1 bg-surface rounded-2xl p-4 items-center">
          <Text className="text-3xl font-bold text-primary">{insights.stats?.active_cameras ?? 0}</Text>
          <Text className="text-text-secondary text-xs mt-1">Cameras</Text>
        </View>
      </View>

      {/* Label distribution */}
      {insights.labels && insights.labels.length > 0 && (
        <View className="mx-4 mt-4 bg-surface rounded-2xl p-4">
          <Text className="text-text-primary font-semibold mb-3">Detections by Type</Text>
          {insights.labels.slice(0, 6).map((l) => (
            <View key={l.label} className="mb-2">
              <View className="flex-row justify-between mb-1">
                <Text className="text-text-primary text-sm">
                  {getLabelEmoji(l.label)} {formatLabel(l.label)}
                </Text>
                <Text className="text-text-secondary text-sm">{l.count}</Text>
              </View>
              <View className="h-1.5 bg-surface-2 rounded-full overflow-hidden">
                <View
                  className="h-full bg-primary rounded-full"
                  style={{ width: `${Math.min(l.percentage, 100)}%` }}
                />
              </View>
            </View>
          ))}
        </View>
      )}

      {/* Recent events */}
      {insights.recent_events && insights.recent_events.length > 0 && (
        <View className="mt-4">
          <Text className="text-text-primary font-semibold mx-4 mb-3">Recent Events</Text>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ paddingHorizontal: 16, gap: 12 }}>
            {insights.recent_events.map((ev) => (
              <TouchableOpacity
                key={ev.id}
                onPress={() => onEventPress(ev.id)}
                className="bg-surface rounded-xl overflow-hidden"
                style={{ width: 140 }}
                activeOpacity={0.8}
              >
                <Image
                  source={{ uri: `${baseUrl}/api/events/${ev.id}/thumbnail.webp` }}
                  style={{ width: 140, height: 90 }}
                  resizeMode="cover"
                />
                <View className="p-2">
                  <Text className="text-text-primary text-xs font-medium" numberOfLines={1}>
                    {getLabelEmoji(ev.label)} {formatLabel(ev.label)}
                  </Text>
                  <Text className="text-text-secondary text-xs">{ev.camera}</Text>
                  <Text className="text-text-secondary text-xs">{formatRelativeTime(ev.start_time)}</Text>
                </View>
              </TouchableOpacity>
            ))}
          </ScrollView>
        </View>
      )}

      {/* Camera grid */}
      {insights.cameras && insights.cameras.length > 0 && (
        <View className="mx-4 mt-4 bg-surface rounded-2xl p-4">
          <Text className="text-text-primary font-semibold mb-3">Camera Activity</Text>
          {insights.cameras.map((cam) => (
            <View key={cam.name} className="flex-row items-center justify-between py-2 border-b border-surface-2 last:border-0">
              <Text className="text-text-primary text-sm">📷 {cam.name}</Text>
              <View className="items-end">
                <Text className="text-text-secondary text-sm">{cam.total_events} events</Text>
                {cam.top_labels.length > 0 && (
                  <Text className="text-text-secondary text-xs">{cam.top_labels.map(getLabelEmoji).join(" ")}</Text>
                )}
              </View>
            </View>
          ))}
        </View>
      )}
    </ScrollView>
  );
}
