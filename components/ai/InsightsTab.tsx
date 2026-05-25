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

const THREAT_COLORS: Record<number, string> = { 0: "#22c55e", 1: "#f59e0b", 2: "#ef4444" };
const THREAT_LABELS: Record<number, string> = { 0: "LOW", 1: "MED", 2: "HIGH" };

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
          AI Insights not yet available.{"\n"}Pull down to retry.
        </Text>
      </ScrollView>
    );
  }

  const totalLabels = insights.labels?.reduce((s, l) => s + l.count, 0) || 1;

  return (
    <ScrollView
      contentContainerStyle={{ paddingBottom: 24 }}
      refreshControl={<RefreshControl refreshing={false} onRefresh={() => mutate()} tintColor="#00d4ff" />}
    >
      {/* Stat cards */}
      <View style={{ flexDirection: "row", marginHorizontal: 16, marginTop: 16, gap: 10 }}>
        <StatCard value={insights.today_count ?? 0}    label="Today"     color="#00d4ff" />
        <StatCard value={insights.total_events ?? 0}   label={`${insights.days ?? 7}d Total`} color="#a855f7" />
        <StatCard value={insights.after_hours_count ?? 0} label="After Hrs" color="#f59e0b" />
      </View>

      {/* Label distribution */}
      {insights.labels && insights.labels.length > 0 && (
        <View style={{ marginHorizontal: 16, marginTop: 16, backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 6, marginBottom: 10 }}>
            <Ionicons name="bar-chart" size={16} color="#00d4ff" />
            <Text style={{ color: "#f1f5f9", fontWeight: "700", fontSize: 15 }}>Detections by Type</Text>
          </View>
          {insights.labels.slice(0, 8).map((l) => {
            const pct = Math.round((l.count / totalLabels) * 100);
            return (
              <View key={l.label} style={{ marginBottom: 8 }}>
                <View style={{ flexDirection: "row", justifyContent: "space-between", marginBottom: 4 }}>
                  <Text style={{ color: "#f1f5f9", fontSize: 13 }}>
                    {getLabelEmoji(l.label)} {formatLabel(l.label)}
                  </Text>
                  <Text style={{ color: "#64748b", fontSize: 13, fontWeight: "600" }}>{l.count}</Text>
                </View>
                <View style={{ height: 6, backgroundColor: "#0a0f1e", borderRadius: 3, overflow: "hidden" }}>
                  <View style={{ height: 6, backgroundColor: "#00d4ff", width: `${Math.min(pct, 100)}%`, borderRadius: 3 }} />
                </View>
              </View>
            );
          })}
        </View>
      )}

      {/* Recent alerts */}
      {insights.recent_alerts && insights.recent_alerts.length > 0 && (
        <View style={{ marginTop: 18 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 6, marginHorizontal: 16, marginBottom: 10 }}>
            <Ionicons name="time" size={16} color="#00d4ff" />
            <Text style={{ color: "#f1f5f9", fontWeight: "700", fontSize: 15 }}>Recent Alerts</Text>
          </View>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ paddingHorizontal: 16, gap: 10 }}>
            {insights.recent_alerts.map((alert) => {
              const threatColor = THREAT_COLORS[alert.threat_level] ?? "#64748b";
              const thumbId = alert.event_id || alert.id;
              return (
                <TouchableOpacity
                  key={alert.id}
                  onPress={() => { haptic.tap(); onEventPress(thumbId); }}
                  style={{ width: 150, backgroundColor: "#1e293b", borderRadius: 12, overflow: "hidden", borderWidth: 1, borderColor: `${threatColor}44` }}
                  activeOpacity={0.85}
                >
                  <Image
                    source={{ uri: `${baseUrl}/api/events/${thumbId}/thumbnail.webp` }}
                    style={{ width: 150, height: 100, backgroundColor: "#0a0f1e" }}
                    resizeMode="cover"
                  />
                  <View style={{ padding: 8 }}>
                    <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: 2 }}>
                      <Text style={{ color: "#f1f5f9", fontSize: 12, fontWeight: "600", flex: 1 }} numberOfLines={1}>
                        {alert.title || alert.objects?.map(o => formatLabel(o)).join(", ")}
                      </Text>
                      <View style={{ backgroundColor: `${threatColor}22`, borderRadius: 4, paddingHorizontal: 4, paddingVertical: 1 }}>
                        <Text style={{ color: threatColor, fontSize: 9, fontWeight: "700" }}>{THREAT_LABELS[alert.threat_level]}</Text>
                      </View>
                    </View>
                    <Text style={{ color: "#64748b", fontSize: 11, marginTop: 1 }} numberOfLines={1}>{alert.camera}</Text>
                    <Text style={{ color: "#475569", fontSize: 10, marginTop: 1 }}>{formatRelativeTime(alert.start_time)}</Text>
                  </View>
                </TouchableOpacity>
              );
            })}
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
            <View key={cam.camera} style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingVertical: 8, borderBottomWidth: i < arr.length - 1 ? 1 : 0, borderBottomColor: "#0a0f1e" }}>
              <Text style={{ color: "#f1f5f9", fontSize: 13, textTransform: "capitalize" }}>{cam.camera.replace(/_/g, " ")}</Text>
              <Text style={{ color: "#94a3b8", fontSize: 12, fontWeight: "600" }}>{cam.count} events</Text>
            </View>
          ))}
        </View>
      )}

      {/* Zones breakdown */}
      {insights.zones && insights.zones.length > 0 && (
        <View style={{ marginHorizontal: 16, marginTop: 12, backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 6, marginBottom: 10 }}>
            <Ionicons name="locate" size={16} color="#a855f7" />
            <Text style={{ color: "#f1f5f9", fontWeight: "700", fontSize: 15 }}>Zones</Text>
          </View>
          {insights.zones.map((z, i, arr) => (
            <View key={z.zone} style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingVertical: 8, borderBottomWidth: i < arr.length - 1 ? 1 : 0, borderBottomColor: "#0a0f1e" }}>
              <Text style={{ color: "#f1f5f9", fontSize: 13, textTransform: "capitalize" }}>{z.zone.replace(/_/g, " ")}</Text>
              <Text style={{ color: "#94a3b8", fontSize: 12, fontWeight: "600" }}>{z.count} events</Text>
            </View>
          ))}
        </View>
      )}
    </ScrollView>
  );
}
