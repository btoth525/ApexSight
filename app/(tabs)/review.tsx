import { useState, useCallback } from "react";
import { View, Text, SectionList, TouchableOpacity, RefreshControl } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { useFrigateEvents } from "@/hooks/useFrigateEvents";
import { ReviewCard } from "@/components/events/ReviewCard";
import { EventDetailSheet } from "@/components/events/EventDetailSheet";
import { Skeleton } from "@/components/ui/Skeleton";
import { ReviewItem } from "@/types/event";
import { formatDate } from "@/utils/timeUtil";

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

export default function ReviewScreen() {
  const [severity, setSeverity] = useState<"alert" | "detection">("alert");
  const [selectedItem, setSelectedItem] = useState<ReviewItem | null>(null);

  const { data, isLoading, mutate } = useFrigateApi<ReviewItem[]>(
    `/reviews?limit=100&severity=${severity}`
  );

  useFrigateEvents(useCallback((event: unknown) => {
    const e = event as { type?: string };
    if (e.type === "reviews") mutate();
  }, [mutate]));

  const sections = data ? groupByDate(data) : [];

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaView className="flex-1 bg-background" edges={["top"]}>
        {/* Header */}
        <View className="px-4 py-3 border-b border-surface-2">
          <Text className="text-text-primary text-xl font-bold mb-3">Review</Text>
          {/* Severity filter */}
          <View className="flex-row bg-surface rounded-xl p-1 gap-1">
            {(["alert", "detection"] as const).map((s) => (
              <TouchableOpacity
                key={s}
                onPress={() => setSeverity(s)}
                className={`flex-1 py-2 rounded-lg items-center ${severity === s ? "bg-primary" : ""}`}
              >
                <Text className={`text-sm font-medium capitalize ${severity === s ? "text-white" : "text-text-secondary"}`}>
                  {s === "alert" ? "🔔 Alerts" : "👁 Detections"}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        {isLoading ? (
          <View className="p-4 gap-3">
            {[1, 2, 3, 4, 5].map((i) => <Skeleton key={i} height={72} borderRadius={12} />)}
          </View>
        ) : (
          <SectionList
            sections={sections}
            keyExtractor={(item) => item.id}
            renderItem={({ item }) => (
              <ReviewCard item={item} onPress={() => setSelectedItem(item)} />
            )}
            renderSectionHeader={({ section }) => (
              <View className="px-4 py-2 bg-background">
                <Text className="text-text-secondary text-xs font-semibold uppercase tracking-wide">
                  {section.title}
                </Text>
              </View>
            )}
            refreshControl={
              <RefreshControl refreshing={isLoading} onRefresh={() => mutate()} tintColor="#00b4d8" />
            }
            ListEmptyComponent={() => (
              <View className="flex-1 items-center justify-center py-20">
                <Text className="text-4xl mb-4">🔔</Text>
                <Text className="text-text-primary text-lg">No {severity}s found</Text>
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
