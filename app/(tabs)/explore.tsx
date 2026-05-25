import { useState, useCallback } from "react";
import {
  View, Text, FlatList, TextInput, TouchableOpacity,
  Image, Dimensions, ActivityIndicator, RefreshControl
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { apiClient } from "@/utils/apiClient";
import { EventDetailSheet } from "@/components/events/EventDetailSheet";
import { Skeleton } from "@/components/ui/Skeleton";
import { FrigateEvent } from "@/types/event";
import { useAuthStore } from "@/stores/authStore";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";

const { width: SCREEN_WIDTH } = Dimensions.get("window");
const THUMB_SIZE = (SCREEN_WIDTH - 4) / 3;

type ExploreGroup = {
  label: string;
  camera?: string;
  thumb_path: string;
  count: number;
};

export default function ExploreScreen() {
  const { baseUrl } = useAuthStore();
  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<FrigateEvent[] | null>(null);
  const [selectedEvent, setSelectedEvent] = useState<FrigateEvent | null>(null);
  const [similarResults, setSimilarResults] = useState<FrigateEvent[] | null>(null);

  const { data: groups, isLoading, mutate } = useFrigateApi<ExploreGroup[]>("/events/explore");

  const handleSearch = useCallback(async (q: string) => {
    if (!q.trim()) { setSearchResults(null); return; }
    setSearching(true);
    try {
      const res = await apiClient.get(`/events/search?query=${encodeURIComponent(q)}&limit=50`);
      setSearchResults(res.data);
    } catch {
      setSearchResults([]);
    } finally {
      setSearching(false);
    }
  }, []);

  const handleSimilar = useCallback(async (event: FrigateEvent) => {
    try {
      const res = await apiClient.post(`/events/${event.id}/similar`);
      setSimilarResults(res.data);
      setSelectedEvent(null);
    } catch {}
  }, []);

  const displayItems: FrigateEvent[] = similarResults ?? searchResults ?? [];
  const showGrid = displayItems.length > 0;

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaView className="flex-1 bg-background" edges={["top"]}>
        {/* Header + Search */}
        <View className="px-4 py-3 border-b border-surface-2">
          <Text className="text-text-primary text-xl font-bold mb-3">Explore</Text>
          <View className="flex-row items-center bg-surface rounded-xl px-3 gap-2">
            <Text className="text-text-secondary">🔍</Text>
            <TextInput
              className="flex-1 py-3 text-text-primary text-base"
              placeholder="Search events..."
              placeholderTextColor="#94a3b8"
              value={query}
              onChangeText={setQuery}
              onSubmitEditing={() => handleSearch(query)}
              returnKeyType="search"
            />
            {query.length > 0 && (
              <TouchableOpacity onPress={() => { setQuery(""); setSearchResults(null); setSimilarResults(null); }}>
                <Text className="text-text-secondary text-lg">✕</Text>
              </TouchableOpacity>
            )}
          </View>
          {similarResults && (
            <TouchableOpacity
              onPress={() => setSimilarResults(null)}
              className="mt-2 flex-row items-center gap-2"
            >
              <Text className="text-primary text-sm">← Back to explore</Text>
            </TouchableOpacity>
          )}
        </View>

        {searching && (
          <View className="flex-1 items-center justify-center">
            <ActivityIndicator color="#00b4d8" />
          </View>
        )}

        {!searching && showGrid && (
          <FlatList
            data={displayItems}
            keyExtractor={(item) => item.id}
            numColumns={3}
            columnWrapperStyle={{ gap: 2 }}
            ItemSeparatorComponent={() => <View style={{ height: 2 }} />}
            renderItem={({ item }) => (
              <TouchableOpacity
                style={{ width: THUMB_SIZE, height: THUMB_SIZE }}
                onPress={() => setSelectedEvent(item)}
                activeOpacity={0.85}
              >
                <Image
                  source={{ uri: `${baseUrl}/api/events/${item.id}/thumbnail.webp` }}
                  style={{ width: THUMB_SIZE, height: THUMB_SIZE }}
                  resizeMode="cover"
                />
                <View className="absolute bottom-0 left-0 right-0 bg-black/50 py-0.5 px-1">
                  <Text className="text-white text-xs" numberOfLines={1}>
                    {getLabelEmoji(item.label)} {formatLabel(item.label)}
                  </Text>
                </View>
              </TouchableOpacity>
            )}
            contentContainerStyle={{ paddingBottom: 20 }}
          />
        )}

        {!searching && !showGrid && (
          isLoading ? (
            <View className="p-4 flex-row flex-wrap gap-2">
              {[1,2,3,4,5,6].map(i => <Skeleton key={i} width={THUMB_SIZE} height={THUMB_SIZE} borderRadius={0} />)}
            </View>
          ) : (
            <FlatList
              data={groups ?? []}
              keyExtractor={(item, i) => `${item.label}-${i}`}
              numColumns={3}
              columnWrapperStyle={{ gap: 2 }}
              ItemSeparatorComponent={() => <View style={{ height: 2 }} />}
              renderItem={({ item }) => (
                <TouchableOpacity
                  style={{ width: THUMB_SIZE, height: THUMB_SIZE }}
                  onPress={() => handleSearch(item.label)}
                  activeOpacity={0.85}
                >
                  <Image
                    source={{ uri: `${baseUrl}${item.thumb_path}` }}
                    style={{ width: THUMB_SIZE, height: THUMB_SIZE }}
                    resizeMode="cover"
                  />
                  <View className="absolute inset-0 bg-black/30" />
                  <View className="absolute bottom-0 left-0 right-0 bg-black/60 py-1 px-1">
                    <Text className="text-white text-xs font-medium" numberOfLines={1}>
                      {getLabelEmoji(item.label)} {formatLabel(item.label)}
                    </Text>
                    {item.count > 0 && (
                      <Text className="text-white/70 text-xs">{item.count}</Text>
                    )}
                  </View>
                </TouchableOpacity>
              )}
              refreshControl={
                <RefreshControl refreshing={isLoading} onRefresh={() => mutate()} tintColor="#00b4d8" />
              }
              contentContainerStyle={{ paddingBottom: 20 }}
            />
          )
        )}

        {selectedEvent && (
          <EventDetailSheet
            event={selectedEvent}
            onClose={() => setSelectedEvent(null)}
            onOpenExplore={() => {}}
          />
        )}
      </SafeAreaView>
    </GestureHandlerRootView>
  );
}
