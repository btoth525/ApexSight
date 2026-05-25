import { useState, useCallback } from "react";
import {
  View, Text, FlatList, TextInput, TouchableOpacity,
  Image, Dimensions, ActivityIndicator, RefreshControl, StatusBar
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { Ionicons } from "@expo/vector-icons";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { apiClient } from "@/utils/apiClient";
import { EventDetailSheet } from "@/components/events/EventDetailSheet";
import { Skeleton } from "@/components/ui/Skeleton";
import { FrigateEvent } from "@/types/event";
import { useAuthStore } from "@/stores/authStore";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";
import { haptic } from "@/utils/haptics";

const { width: SCREEN_WIDTH } = Dimensions.get("window");
const THUMB_SIZE = (SCREEN_WIDTH - 4) / 3;

type ExploreGroup = { label: string; camera?: string; thumb_path: string; count: number };

export default function ExploreScreen() {
  const { baseUrl } = useAuthStore();
  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<FrigateEvent[] | null>(null);
  const [selectedEvent, setSelectedEvent] = useState<FrigateEvent | null>(null);
  const [similarResults, setSimilarResults] = useState<FrigateEvent[] | null>(null);

  // Fall back to recent events if /events/explore is unavailable
  const { data: groups, isLoading, mutate } = useFrigateApi<ExploreGroup[]>("/events/explore");
  const { data: recentEvents } = useFrigateApi<FrigateEvent[]>(
    !groups || groups.length === 0 ? "/events?limit=100&has_snapshot=1" : null
  );

  const handleSearch = useCallback(async (q: string) => {
    if (!q.trim()) { setSearchResults(null); return; }
    haptic.tap();
    setSearching(true);
    try {
      const res = await apiClient.get(`/events?label=${encodeURIComponent(q)}&limit=100&has_snapshot=1`);
      setSearchResults(res.data);
    } catch {
      setSearchResults([]);
    } finally {
      setSearching(false);
    }
  }, []);

  const handleSimilar = useCallback(async (event: FrigateEvent) => {
    haptic.medium();
    try {
      const res = await apiClient.post(`/events/${event.id}/similar`);
      setSimilarResults(res.data);
      setSelectedEvent(null);
    } catch {}
  }, []);

  // Build thumbnail URL — handle both full paths and relative paths
  const thumbUrl = (item: FrigateEvent) =>
    `${baseUrl}/api/events/${item.id}/thumbnail.webp`;

  const groupThumbUrl = (path: string) => {
    if (path.startsWith("/api/") || path.startsWith("http")) return `${baseUrl}${path}`;
    // Likely a media path — use the API proxy
    return `${baseUrl}/api${path.startsWith("/") ? path : "/" + path}`;
  };

  const displayItems: FrigateEvent[] = similarResults ?? searchResults ?? [];
  const showEventGrid = displayItems.length > 0;

  // Group view falls back to recent events if explore endpoint not available
  const fallbackItems: FrigateEvent[] = recentEvents ?? [];

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaView style={{ flex: 1, backgroundColor: "#0a0f1e" }} edges={["top"]}>
        <StatusBar barStyle="light-content" />

        {/* Header */}
        <View style={{ paddingHorizontal: 16, paddingTop: 12, paddingBottom: 12, borderBottomWidth: 1, borderBottomColor: "#1e293b" }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 8, marginBottom: 10 }}>
            <Ionicons name="search" size={20} color="#00d4ff" />
            <Text style={{ color: "#f1f5f9", fontSize: 20, fontWeight: "700", letterSpacing: -0.3 }}>Explore</Text>
          </View>
          <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#1e293b", borderRadius: 12, paddingHorizontal: 12, gap: 8 }}>
            <Ionicons name="search-outline" size={16} color="#475569" />
            <TextInput
              style={{ flex: 1, paddingVertical: 11, color: "#f1f5f9", fontSize: 15 }}
              placeholder="Search by label, camera..."
              placeholderTextColor="#475569"
              value={query}
              onChangeText={setQuery}
              onSubmitEditing={() => handleSearch(query)}
              returnKeyType="search"
            />
            {query.length > 0 && (
              <TouchableOpacity onPress={() => { setQuery(""); setSearchResults(null); setSimilarResults(null); }}>
                <Ionicons name="close-circle" size={18} color="#475569" />
              </TouchableOpacity>
            )}
          </View>
          {similarResults && (
            <TouchableOpacity
              onPress={() => { haptic.tap(); setSimilarResults(null); }}
              style={{ marginTop: 8, flexDirection: "row", alignItems: "center", gap: 4 }}
            >
              <Ionicons name="arrow-back" size={14} color="#00d4ff" />
              <Text style={{ color: "#00d4ff", fontSize: 13 }}>Back to explore</Text>
            </TouchableOpacity>
          )}
        </View>

        {searching && (
          <View style={{ flex: 1, alignItems: "center", justifyContent: "center" }}>
            <ActivityIndicator color="#00d4ff" size="large" />
            <Text style={{ color: "#475569", marginTop: 12, fontSize: 13 }}>Searching...</Text>
          </View>
        )}

        {!searching && showEventGrid && (
          <FlatList
            data={displayItems}
            keyExtractor={(item) => item.id}
            numColumns={3}
            columnWrapperStyle={{ gap: 2 }}
            ItemSeparatorComponent={() => <View style={{ height: 2 }} />}
            renderItem={({ item }) => (
              <TouchableOpacity
                style={{ width: THUMB_SIZE, height: THUMB_SIZE }}
                onPress={() => { haptic.tap(); setSelectedEvent(item); }}
                activeOpacity={0.85}
              >
                <Image
                  source={{ uri: thumbUrl(item) }}
                  style={{ width: THUMB_SIZE, height: THUMB_SIZE }}
                  resizeMode="cover"
                />
                <View style={{ position: "absolute", bottom: 0, left: 0, right: 0, backgroundColor: "rgba(0,0,0,0.6)", paddingHorizontal: 4, paddingVertical: 3 }}>
                  <Text style={{ color: "#fff", fontSize: 11 }} numberOfLines={1}>
                    {getLabelEmoji(item.label)} {formatLabel(item.label)}
                  </Text>
                </View>
              </TouchableOpacity>
            )}
            contentContainerStyle={{ paddingBottom: 20 }}
          />
        )}

        {!searching && !showEventGrid && (
          isLoading ? (
            <View style={{ padding: 2, flexDirection: "row", flexWrap: "wrap", gap: 2 }}>
              {[1,2,3,4,5,6,7,8,9].map(i => <Skeleton key={i} width={THUMB_SIZE} height={THUMB_SIZE} borderRadius={0} />)}
            </View>
          ) : groups && groups.length > 0 ? (
            <FlatList
              data={groups}
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
                    source={{ uri: groupThumbUrl(item.thumb_path) }}
                    style={{ width: THUMB_SIZE, height: THUMB_SIZE, backgroundColor: "#1e293b" }}
                    resizeMode="cover"
                  />
                  <View style={{ position: "absolute", inset: 0, backgroundColor: "rgba(0,0,0,0.25)" }} />
                  <View style={{ position: "absolute", bottom: 0, left: 0, right: 0, backgroundColor: "rgba(0,0,0,0.65)", paddingHorizontal: 4, paddingVertical: 4 }}>
                    <Text style={{ color: "#fff", fontSize: 12, fontWeight: "600" }} numberOfLines={1}>
                      {getLabelEmoji(item.label)} {formatLabel(item.label)}
                    </Text>
                    {item.count > 0 && (
                      <Text style={{ color: "rgba(255,255,255,0.6)", fontSize: 10 }}>{item.count} events</Text>
                    )}
                  </View>
                </TouchableOpacity>
              )}
              refreshControl={<RefreshControl refreshing={isLoading} onRefresh={() => mutate()} tintColor="#00d4ff" />}
              contentContainerStyle={{ paddingBottom: 20 }}
            />
          ) : (
            // Fallback: show recent events as a grid
            <FlatList
              data={fallbackItems}
              keyExtractor={(item) => item.id}
              numColumns={3}
              columnWrapperStyle={{ gap: 2 }}
              ItemSeparatorComponent={() => <View style={{ height: 2 }} />}
              ListHeaderComponent={() => (
                <View style={{ padding: 12, paddingBottom: 6 }}>
                  <Text style={{ color: "#475569", fontSize: 12 }}>Recent detections</Text>
                </View>
              )}
              renderItem={({ item }) => (
                <TouchableOpacity
                  style={{ width: THUMB_SIZE, height: THUMB_SIZE }}
                  onPress={() => { haptic.tap(); setSelectedEvent(item); }}
                  activeOpacity={0.85}
                >
                  <Image
                    source={{ uri: thumbUrl(item) }}
                    style={{ width: THUMB_SIZE, height: THUMB_SIZE, backgroundColor: "#1e293b" }}
                    resizeMode="cover"
                  />
                  <View style={{ position: "absolute", bottom: 0, left: 0, right: 0, backgroundColor: "rgba(0,0,0,0.6)", paddingHorizontal: 4, paddingVertical: 3 }}>
                    <Text style={{ color: "#fff", fontSize: 11 }} numberOfLines={1}>
                      {getLabelEmoji(item.label)} {formatLabel(item.label)}
                    </Text>
                  </View>
                </TouchableOpacity>
              )}
              refreshControl={<RefreshControl refreshing={false} onRefresh={() => mutate()} tintColor="#00d4ff" />}
              contentContainerStyle={{ paddingBottom: 20 }}
            />
          )
        )}

        {selectedEvent && (
          <EventDetailSheet
            event={selectedEvent}
            onClose={() => setSelectedEvent(null)}
            onOpenExplore={(id) => handleSimilar({ id } as FrigateEvent)}
          />
        )}
      </SafeAreaView>
    </GestureHandlerRootView>
  );
}
