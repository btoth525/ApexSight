import { View, Text, ScrollView, Image, TouchableOpacity, RefreshControl } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { useAuthStore } from "@/stores/authStore";
import { AIInsights } from "@/types/api";
import { Skeleton } from "@/components/ui/Skeleton";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";
import { formatRelativeTime } from "@/utils/timeUtil";
import { haptic } from "@/utils/haptics";

type Props = { onEventPress: (eventId: string) => void };

function StatCard({ value, label, color }: { value: number | string; label: string; color: string }) {
  return (
    <View style={{ flex: 1, backgroundColor: "#1e293b", borderRadius: 14, padding: 14, alignItems: "center" }}>
      <Text style={{ fontSize: 26, fontWeight: "800", color, letterSpacing: -0.5 }}>{value}</Text>
      <Text style={{ color: "#64748b", fontSize: 11, marginTop: 2, fontWeight: "600", textTransform: "uppercase", letterSpacing: 0.5 }}>{label}</Text>
    </View>
  );
}

export function InsightsTab({ onEventPress }: Props) {
  const { baseUrl } = useAuthStore();
  const { data: insights, isLoading, mutate } = useFrigateApi<AIInsights>("/ai/insights");

  if (isLoading) {
    return (
      <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
        <Skeleton height={92} borderRadius={14} />
        <Skeleton height={220} borderRadius={14} />
        <Skeleton height={160} borderRadius={14} />
      </ScrollView>
    );
  }

  if (!insights) {
    return (
      <ScrollView
        refreshControl={<RefreshControl refreshing={false} onRefresh={() => mutate()} tintColor="#00d4ff" />}
        contentContainerStyle={{ flex: 1, alignItems: "center", justifyContent: "center", padding: 32 }}
      >
        <Ionicons name="cube-outline" size={48} color="#334155" />
        <Text style={{ color: "#f1f5f9", fontSize: 16, fontWeight: "600", marginTop: 16 }}>No insights available</Text>
        <Text style={{ color: "#64748b", fontSize: 13, marginTop: 6, textAlign: "center" }}>
          Frigate AI Insights endpoint not configured.{"\n"}Pull down to retry.
        </Text>
      </ScrollView>
    );
  }

  return (
    <ScrollView
      contentContainerStyle={{ paddingBottom: 24 }}
      refreshControl={<RefreshControl refreshing={false} onRefresh={() => mutate()} tintColor="#00d4ff" />}
    >
      {/* Stat cards */}
      <View style={{ flexDirection: "row", marginHorizontal: 16, marginTop: 16, gap: 10 }}>
        <StatCard value={insights.stats?.total_events_today ?? 0} label="Today"    color="#00d4ff" />
        <StatCard value={insights.stats?.total_events_week  ?? 0} label="This Wk"  color="#a855f7" />
        <StatCard value={insights.stats?.active_cameras     ?? 0} label="Cameras"  color="#22c55e" />
      </View>

      {/* Label distribution */}
      {insights.labels && insights.labels.length > 0 && (
        <View style={{ marginHorizontal: 16, marginTop: 16, backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 6, marginBottom: 10 }}>
            <Ionicons name="bar-chart" size={16} color="#00d4ff" />
            <Text style={{ color: "#f1f5f9", fontWeight: "700", fontSize: 15 }}>Detections by Type</Text>
          </View>
          {insights.labels.slice(0, 8).map((l) => (
            <View key={l.label} style={{ marginBottom: 8 }}>
              <View style={{ flexDirection: "row", justifyContent: "space-between", marginBottom: 4 }}>
                <Text style={{ color: "#f1f5f9", fontSize: 13 }}>
                  {getLabelEmoji(l.label)} {formatLabel(l.label)}
                </Text>
                <Text style={{ color: "#64748b", fontSize: 13, fontWeight: "600" }}>{l.count}</Text>
              </View>
              <View style={{ height: 6, backgroundColor: "#0a0f1e", borderRadius: 3, overflow: "hidden" }}>
                <View style={{ height: 6, backgroundColor: "#00d4ff", width: `${Math.min(l.percentage, 100)}%`, borderRadius: 3 }} />
              </View>
            </View>
          ))}
        </View>
      )}

      {/* Recent events horizontal scroll */}
      {insights.recent_events && insights.recent_events.length > 0 && (
        <View style={{ marginTop: 18 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 6, marginHorizontal: 16, marginBottom: 10 }}>
            <Ionicons name="time" size={16} color="#00d4ff" />
            <Text style={{ color: "#f1f5f9", fontWeight: "700", fontSize: 15 }}>Recent Events</Text>
          </View>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ paddingHorizontal: 16, gap: 10 }}>
            {insights.recent_events.map((ev) => (
              <TouchableOpacity
                key={ev.id}
                onPress={() => { haptic.tap(); onEventPress(ev.id); }}
                style={{ width: 150, backgroundColor: "#1e293b", borderRadius: 12, overflow: "hidden" }}
                activeOpacity={0.85}
              >
                <Image
                  source={{ uri: `${baseUrl}/api/events/${ev.id}/thumbnail.webp` }}
                  style={{ width: 150, height: 100, backgroundColor: "#0a0f1e" }}
                  resizeMode="cover"
                />
                <View style={{ padding: 8 }}>
                  <Text style={{ color: "#f1f5f9", fontSize: 12, fontWeight: "600" }} numberOfLines={1}>
                    {getLabelEmoji(ev.label)} {formatLabel(ev.label)}
                  </Text>
                  <Text style={{ color: "#64748b", fontSize: 11, marginTop: 2 }} numberOfLines={1}>{ev.camera}</Text>
                  <Text style={{ color: "#475569", fontSize: 10, marginTop: 1 }}>{formatRelativeTime(ev.start_time)}</Text>
                </View>
              </TouchableOpacity>
            ))}
          </ScrollView>
        </View>
      )}

      {/* Camera activity */}
      {insights.cameras && insights.cameras.length > 0 && (
        <View style={{ marginHorizontal: 16, marginTop: 18, backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 6, marginBottom: 10 }}>
            <Ionicons name="videocam" size={16} color="#00d4ff" />
            <Text style={{ color: "#f1f5f9", fontWeight: "700", fontSize: 15 }}>Camera Activity</Text>
          </View>
          {insights.cameras.map((cam, i, arr) => (
            <View key={cam.name} style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingVertical: 8, borderBottomWidth: i < arr.length - 1 ? 1 : 0, borderBottomColor: "#0a0f1e" }}>
              <Text style={{ color: "#f1f5f9", fontSize: 13, textTransform: "capitalize" }}>{cam.name.replace(/_/g, " ")}</Text>
              <View style={{ alignItems: "flex-end" }}>
                <Text style={{ color: "#94a3b8", fontSize: 12, fontWeight: "600" }}>{cam.total_events} events</Text>
                {cam.top_labels.length > 0 && (
                  <Text style={{ color: "#64748b", fontSize: 11 }}>{cam.top_labels.map(getLabelEmoji).join(" ")}</Text>
                )}
              </View>
            </View>
          ))}
        </View>
      )}
    </ScrollView>
  );
}
