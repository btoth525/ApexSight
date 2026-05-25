import { useState, useCallback } from "react";
import { View, Text, SectionList, TouchableOpacity, RefreshControl, StatusBar } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { Ionicons } from "@expo/vector-icons";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { useFrigateEvents } from "@/hooks/useFrigateEvents";
import { ReviewCard } from "@/components/events/ReviewCard";
import { EventDetailSheet } from "@/components/events/EventDetailSheet";
import { Skeleton } from "@/components/ui/Skeleton";
import { ReviewItem } from "@/types/event";
import { formatDate } from "@/utils/timeUtil";
import { haptic } from "@/utils/haptics";

type Section = { title: string; data: ReviewItem[] };

function groupByDate(items: ReviewItem[]): Section[] {
  const map = new Map<string, ReviewItem[]>();
  for (const item of items) {
    const key = formatDate(item.start_time);
    if (!map.has(key)) map.set(key, []);
    map.get(key)!.push(item);
  }
  return Array.from(map.entries()).map(([title, data]) => ({ title, data }));
}

// Default: last 30 days
const after30Days = () => Math.floor(Date.now() / 1000) - 30 * 24 * 60 * 60;

export default function ReviewScreen() {
  const [severity, setSeverity] = useState<"alert" | "detection">("alert");
  const [selectedItem, setSelectedItem] = useState<ReviewItem | null>(null);

  const after = after30Days();
  const { data, isLoading, mutate } = useFrigateApi<ReviewItem[]>(
    `/reviews?limit=200&severity=${severity}&after=${after}`
  );

  useFrigateEvents(useCallback((event: unknown) => {
    const e = event as { type?: string };
    if (e.type === "reviews") mutate();
  }, [mutate]));

  const sections = data ? groupByDate(data) : [];

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaView style={{ flex: 1, backgroundColor: "#0a0f1e" }} edges={["top"]}>
        <StatusBar barStyle="light-content" />

        {/* Header */}
        <View style={{ paddingHorizontal: 16, paddingTop: 12, paddingBottom: 12, borderBottomWidth: 1, borderBottomColor: "#1e293b" }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 8, marginBottom: 12 }}>
            <Ionicons name="notifications" size={20} color="#00d4ff" />
            <Text style={{ color: "#f1f5f9", fontSize: 20, fontWeight: "700", letterSpacing: -0.3 }}>Review</Text>
            {data && data.length > 0 && (
              <View style={{ backgroundColor: "#00d4ff22", borderRadius: 99, paddingHorizontal: 8, paddingVertical: 2 }}>
                <Text style={{ color: "#00d4ff", fontSize: 11, fontWeight: "700" }}>{data.length}</Text>
              </View>
            )}
          </View>
          {/* Severity toggle */}
          <View style={{ flexDirection: "row", backgroundColor: "#1e293b", borderRadius: 12, padding: 3, gap: 3 }}>
            {([["alert", "notifications", "Alerts"], ["detection", "eye", "Detections"]] as const).map(([s, icon, label]) => (
              <TouchableOpacity
                key={s}
                onPress={() => { haptic.tap(); setSeverity(s); }}
                style={{ flex: 1, paddingVertical: 8, borderRadius: 10, alignItems: "center", flexDirection: "row", justifyContent: "center", gap: 6, backgroundColor: severity === s ? "#00d4ff" : "transparent" }}
              >
                <Ionicons name={icon as any} size={14} color={severity === s ? "#0a0f1e" : "#64748b"} />
                <Text style={{ fontSize: 13, fontWeight: "600", color: severity === s ? "#0a0f1e" : "#64748b" }}>{label}</Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        {isLoading ? (
          <View style={{ padding: 16, gap: 10 }}>
            {[1, 2, 3, 4, 5].map((i) => <Skeleton key={i} height={76} borderRadius={14} />)}
          </View>
        ) : (
          <SectionList
            sections={sections}
            keyExtractor={(item) => item.id}
            renderItem={({ item }) => (
              <ReviewCard item={item} onPress={() => { haptic.tap(); setSelectedItem(item); }} />
            )}
            renderSectionHeader={({ section }) => (
              <View style={{ paddingHorizontal: 16, paddingVertical: 8, backgroundColor: "#0a0f1e" }}>
                <Text style={{ color: "#475569", fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 1 }}>
                  {section.title}
                </Text>
              </View>
            )}
            refreshControl={
              <RefreshControl refreshing={isLoading} onRefresh={() => mutate()} tintColor="#00d4ff" />
            }
            ListEmptyComponent={() => (
              <View style={{ flex: 1, alignItems: "center", justifyContent: "center", paddingTop: 80 }}>
                <Ionicons name="notifications-off-outline" size={48} color="#334155" />
                <Text style={{ color: "#f1f5f9", fontSize: 17, fontWeight: "600", marginTop: 16 }}>No {severity}s found</Text>
                <Text style={{ color: "#475569", fontSize: 13, marginTop: 6 }}>Last 30 days · Pull to refresh</Text>
              </View>
            )}
            contentContainerStyle={{ paddingBottom: 20 }}
          />
        )}

        {selectedItem && (
          <EventDetailSheet
            event={selectedItem}
            onClose={() => setSelectedItem(null)}
            onReviewed={() => mutate()}
          />
        )}
      </SafeAreaView>
    </GestureHandlerRootView>
  );
}
