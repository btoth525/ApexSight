import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  Image,
  RefreshControl,
  ScrollView,
  Text,
  View,
} from "react-native";
import { useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { AppleMaterial, ApplePressable, apple } from "@/components/AppleMaterial";
import { pendingDeeplink } from "@/stores/pendingDeeplink";
import { useAuthStore } from "@/stores/authStore";
import { apiClient } from "@/utils/apiClient";
import { apiImageUrl, mediaHeaders } from "@/utils/frigateMedia";
import type { CameraConfig, FrigateEvent } from "@/utils/frigateTypes";
import { formatLabel, getLabelEmoji } from "@/utils/labelUtil";
import { haptic } from "@/utils/haptics";
import { useFrigateEvents } from "@/hooks/useFrigateEvents";
import { notifyFrigateEvent } from "@/utils/nativeNotifications";

function titleize(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (char) => char.toUpperCase());
}

function relativeTime(epoch?: number) {
  if (!epoch) return "Now";
  const seconds = Math.max(0, Math.floor(Date.now() / 1000 - epoch));
  if (seconds < 60) return "Now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

export default function NativeHomeScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { baseUrl, token, username, logout } = useAuthStore();
  const headers = useMemo(() => mediaHeaders(token), [token]);
  const [cameras, setCameras] = useState<string[]>([]);
  const [events, setEvents] = useState<FrigateEvent[]>([]);
  const [selectedCamera, setSelectedCamera] = useState("all");
  const [selectedLabel, setSelectedLabel] = useState("all");
  const [minConfidence, setMinConfidence] = useState(0.55);
  const [notificationsOn, setNotificationsOn] = useState(true);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const notificationCooldownRef = useRef<Record<string, number>>({});

  const load = useCallback(async () => {
    setError("");
    try {
      const [configResult, eventsResult] = await Promise.allSettled([
        apiClient.get<{ cameras?: Record<string, CameraConfig> }>("/config"),
        apiClient.get<FrigateEvent[]>("/events", { params: { limit: 14 } }),
      ]);

      if (configResult.status === "fulfilled") {
        const names = Object.keys(configResult.value.data?.cameras ?? {});
        setCameras(names);
      }

      if (eventsResult.status === "fulfilled") {
        setEvents(Array.isArray(eventsResult.value.data) ? eventsResult.value.data : []);
      }

      if (configResult.status === "rejected" && eventsResult.status === "rejected") {
        throw new Error("Could not reach Frigate.");
      }
    } catch {
      setError("Could not reach Frigate.");
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const labels = useMemo(
    () => Array.from(new Set(events.map((event) => event.label).filter(Boolean))).sort(),
    [events],
  );

  const visibleEvents = useMemo(
    () => events.filter((event) => {
      if (selectedCamera !== "all" && event.camera !== selectedCamera) return false;
      if (selectedLabel !== "all" && event.label !== selectedLabel) return false;
      if ((event.score ?? event.top_score ?? 1) < minConfidence) return false;
      return true;
    }),
    [events, minConfidence, selectedCamera, selectedLabel],
  );

  useFrigateEvents(useCallback((data: unknown) => {
    const ev = data as { type?: string; after?: Partial<FrigateEvent> };
    if (ev.type !== "new" || !ev.after?.id || !ev.after.label || !ev.after.camera) return;

    const nextEvent: FrigateEvent = {
      id: ev.after.id,
      camera: ev.after.camera,
      label: ev.after.label,
      start_time: ev.after.start_time ?? Math.floor(Date.now() / 1000),
      score: ev.after.score,
      zones: ev.after.zones,
      has_clip: ev.after.has_clip,
      has_snapshot: ev.after.has_snapshot,
    };

    setEvents((current) => [nextEvent, ...current.filter((item) => item.id !== nextEvent.id)].slice(0, 14));
    if (!notificationsOn || (nextEvent.score ?? 1) < minConfidence) return;

    const cooldownKey = `${nextEvent.camera}:${nextEvent.label}`;
    const now = Date.now();
    const lastNotification = notificationCooldownRef.current[cooldownKey] ?? 0;
    if (now - lastNotification < 60_000) return;
    notificationCooldownRef.current[cooldownKey] = now;

    notifyFrigateEvent({
      title: `${formatLabel(nextEvent.label)} detected`,
      body: `${titleize(nextEvent.camera)} - ${Math.round((nextEvent.score ?? 1) * 100)}% confidence`,
      eventId: nextEvent.id,
      camera: nextEvent.camera,
    }).catch(() => {});
  }, [minConfidence, notificationsOn]));

  const openCamera = useCallback((camera: string) => {
    haptic.tap();
    pendingDeeplink.set(`apex:///${encodeURIComponent(camera)}`);
    router.push("/browser");
  }, [router]);

  const openWeb = useCallback(() => {
    haptic.tap();
    router.push("/browser");
  }, [router]);

  const openSystem = useCallback(() => {
    haptic.tap();
    router.push("/system");
  }, [router]);

  const openEvent = useCallback((event: FrigateEvent) => {
    haptic.tap();
    router.push({
      pathname: "/event/[id]",
      params: {
        id: event.id,
        camera: event.camera,
        label: event.label,
        score: event.score !== undefined ? String(event.score) : "",
        start: event.start_time !== undefined ? String(event.start_time) : "",
      },
    });
  }, [router]);

  const refresh = useCallback(() => {
    haptic.tap();
    setRefreshing(true);
    load();
  }, [load]);

  const signOut = useCallback(async () => {
    haptic.medium();
    await logout();
    router.replace("/(auth)/login");
  }, [logout, router]);

  return (
    <View style={{ flex: 1, backgroundColor: apple.colors.background }}>
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={{
          paddingTop: insets.top + 18,
          paddingBottom: insets.bottom + 28,
          paddingHorizontal: 18,
          gap: 18,
        }}
        refreshControl={
          <RefreshControl
            tintColor={apple.colors.cyan}
            refreshing={refreshing}
            onRefresh={refresh}
          />
        }
      >
        <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 12 }}>
          <View style={{ flex: 1 }}>
            <Text style={{ color: apple.colors.label, fontSize: 34, fontWeight: "900" }}>Apex</Text>
            <Text style={{ color: apple.colors.secondaryLabel, fontSize: 14, fontWeight: "700", marginTop: 2 }} numberOfLines={1}>
              {username ? `${username} - ${baseUrl.replace(/^https?:\/\//, "")}` : baseUrl.replace(/^https?:\/\//, "")}
            </Text>
          </View>
          <View style={{ flexDirection: "row", gap: 8 }}>
            <ApplePressable
              onPress={openSystem}
              accessibilityLabel="Open system health"
              style={{
                width: 44,
                height: 44,
                borderRadius: 22,
                alignItems: "center",
                justifyContent: "center",
                backgroundColor: "rgba(48,209,88,0.18)",
              }}
            >
              <Ionicons name="pulse-outline" size={20} color={apple.colors.green} />
            </ApplePressable>
            <ApplePressable
              onPress={openWeb}
              accessibilityLabel="Open Frigate web interface"
              style={{
                width: 44,
                height: 44,
                borderRadius: 22,
                alignItems: "center",
                justifyContent: "center",
                backgroundColor: "rgba(255,255,255,0.12)",
              }}
            >
              <Ionicons name="globe-outline" size={20} color={apple.colors.label} />
            </ApplePressable>
          </View>
        </View>

        {error ? (
          <AppleMaterial tint="systemMaterialDark" intensity={88} contentStyle={{ padding: 16, gap: 10 }}>
            <View style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
              <Ionicons name="warning-outline" size={20} color={apple.colors.orange} />
              <Text style={{ flex: 1, color: apple.colors.label, fontSize: 15, fontWeight: "800" }}>{error}</Text>
            </View>
            <View style={{ flexDirection: "row", gap: 10 }}>
              <ApplePressable onPress={refresh} style={{ flex: 1, borderRadius: 16, backgroundColor: apple.colors.cyan, paddingVertical: 12, alignItems: "center" }}>
                <Text style={{ color: "#061016", fontSize: 14, fontWeight: "900" }}>Retry</Text>
              </ApplePressable>
              <ApplePressable onPress={signOut} style={{ flex: 1, borderRadius: 16, backgroundColor: "rgba(255,255,255,0.12)", paddingVertical: 12, alignItems: "center" }}>
                <Text style={{ color: apple.colors.label, fontSize: 14, fontWeight: "800" }}>Sign Out</Text>
              </ApplePressable>
            </View>
          </AppleMaterial>
        ) : null}

        <AppleMaterial tint="systemChromeMaterialDark" intensity={88} contentStyle={{ padding: 16, gap: 14 }}>
          <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between" }}>
            <View>
              <Text style={{ color: apple.colors.label, fontSize: 20, fontWeight: "900" }}>Live Cameras</Text>
              <Text style={{ color: apple.colors.secondaryLabel, fontSize: 12, fontWeight: "700", marginTop: 2 }}>
                {cameras.length} online
              </Text>
            </View>
            {loading ? <ActivityIndicator color={apple.colors.cyan} /> : null}
          </View>

          <View style={{ gap: 12 }}>
            {cameras.map((camera) => (
              <ApplePressable
                key={camera}
                onPress={() => openCamera(camera)}
                accessibilityLabel={`Open ${titleize(camera)} camera`}
                style={{
                  borderRadius: 22,
                  overflow: "hidden",
                  borderWidth: 1,
                  borderColor: "rgba(255,255,255,0.12)",
                  backgroundColor: "rgba(255,255,255,0.06)",
                }}
              >
                <Image
                  source={{
                    uri: apiImageUrl(baseUrl, `${camera}/latest.jpg`, { bbox: 1 }),
                    headers,
                  }}
                  style={{ width: "100%", aspectRatio: 16 / 9, backgroundColor: "#101014" }}
                  resizeMode="cover"
                />
                <View style={{ padding: 13, flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
                  <View style={{ flex: 1 }}>
                    <Text style={{ color: apple.colors.label, fontSize: 16, fontWeight: "900" }} numberOfLines={1}>
                      {titleize(camera)}
                    </Text>
                    <Text style={{ color: apple.colors.secondaryLabel, fontSize: 12, fontWeight: "700", marginTop: 2 }}>
                      Low-latency WebRTC
                    </Text>
                  </View>
                  <View style={{ width: 36, height: 36, borderRadius: 18, alignItems: "center", justifyContent: "center", backgroundColor: apple.colors.blue }}>
                    <Ionicons name="play" size={16} color="#ffffff" />
                  </View>
                </View>
              </ApplePressable>
            ))}
          </View>
        </AppleMaterial>

        <AppleMaterial tint="systemChromeMaterialDark" intensity={88} contentStyle={{ padding: 16, gap: 14 }}>
          <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between" }}>
            <View>
              <Text style={{ color: apple.colors.label, fontSize: 20, fontWeight: "900" }}>Recent Activity</Text>
              <Text style={{ color: apple.colors.secondaryLabel, fontSize: 12, fontWeight: "700", marginTop: 2 }}>
                {visibleEvents.length} matching alerts
              </Text>
            </View>
            <View style={{ flexDirection: "row", gap: 8 }}>
              <ApplePressable
                onPress={() => {
                  haptic.tap();
                  setNotificationsOn((value) => !value);
                }}
                accessibilityLabel="Toggle notifications"
                style={{
                  width: 38,
                  height: 38,
                  borderRadius: 19,
                  alignItems: "center",
                  justifyContent: "center",
                  backgroundColor: notificationsOn ? "rgba(48,209,88,0.2)" : "rgba(255,255,255,0.12)",
                }}
              >
                <Ionicons name={notificationsOn ? "notifications" : "notifications-off-outline"} size={17} color={notificationsOn ? apple.colors.green : apple.colors.label} />
              </ApplePressable>
              <ApplePressable
                onPress={refresh}
                accessibilityLabel="Refresh activity"
                style={{
                  width: 38,
                  height: 38,
                  borderRadius: 19,
                  alignItems: "center",
                  justifyContent: "center",
                  backgroundColor: "rgba(255,255,255,0.12)",
                }}
              >
                <Ionicons name="refresh" size={17} color={apple.colors.label} />
              </ApplePressable>
            </View>
          </View>

          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
            <FilterChip label="All Cameras" selected={selectedCamera === "all"} onPress={() => setSelectedCamera("all")} />
            {cameras.map((camera) => (
              <FilterChip key={camera} label={titleize(camera)} selected={selectedCamera === camera} onPress={() => setSelectedCamera(camera)} />
            ))}
          </ScrollView>

          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
            <FilterChip label="All Objects" selected={selectedLabel === "all"} onPress={() => setSelectedLabel("all")} />
            {labels.map((eventLabel) => (
              <FilterChip
                key={eventLabel}
                label={`${getLabelEmoji(eventLabel)} ${formatLabel(eventLabel)}`}
                selected={selectedLabel === eventLabel}
                onPress={() => setSelectedLabel(eventLabel)}
              />
            ))}
          </ScrollView>

          <View style={{ flexDirection: "row", gap: 8 }}>
            <FilterChip label="55%+" selected={minConfidence === 0.55} onPress={() => setMinConfidence(0.55)} />
            <FilterChip label="70%+" selected={minConfidence === 0.7} onPress={() => setMinConfidence(0.7)} />
            <FilterChip label="85%+" selected={minConfidence === 0.85} onPress={() => setMinConfidence(0.85)} />
          </View>

          {visibleEvents.length === 0 && !loading ? (
            <Text style={{ color: apple.colors.secondaryLabel, fontSize: 14, fontWeight: "700" }}>
              No matching events.
            </Text>
          ) : null}

          <View style={{ gap: 10 }}>
            {visibleEvents.map((event) => (
              <ApplePressable
                key={event.id}
                onPress={() => openEvent(event)}
                accessibilityLabel={`Open ${formatLabel(event.label)} event`}
                style={{
                  flexDirection: "row",
                  gap: 12,
                  borderRadius: 18,
                  padding: 10,
                  backgroundColor: "rgba(255,255,255,0.07)",
                  borderWidth: 1,
                  borderColor: "rgba(255,255,255,0.1)",
                }}
              >
                <Image
                  source={{
                    uri: apiImageUrl(baseUrl, `events/${event.id}/snapshot.jpg`, { crop: 1, bbox: 1 }),
                    headers,
                  }}
                  style={{ width: 82, height: 82, borderRadius: 14, backgroundColor: "#101014" }}
                  resizeMode="cover"
                />
                <View style={{ flex: 1, justifyContent: "center" }}>
                  <Text style={{ color: apple.colors.label, fontSize: 16, fontWeight: "900" }} numberOfLines={1}>
                    {getLabelEmoji(event.label)} {formatLabel(event.label)}
                  </Text>
                  <Text style={{ color: apple.colors.secondaryLabel, fontSize: 13, fontWeight: "700", marginTop: 4 }} numberOfLines={1}>
                    {titleize(event.camera)} - {relativeTime(event.start_time)}
                  </Text>
                  {event.score !== undefined ? (
                    <Text style={{ color: apple.colors.tertiaryLabel, fontSize: 12, fontWeight: "700", marginTop: 4 }}>
                      {Math.round(event.score * 100)}% confidence
                    </Text>
                  ) : null}
                </View>
                <Ionicons name="chevron-forward" size={18} color={apple.colors.tertiaryLabel} style={{ alignSelf: "center" }} />
              </ApplePressable>
            ))}
          </View>
        </AppleMaterial>
      </ScrollView>
    </View>
  );
}

function FilterChip({ label, selected, onPress }: { label: string; selected: boolean; onPress: () => void }) {
  return (
    <ApplePressable
      onPress={() => {
        haptic.tap();
        onPress();
      }}
      accessibilityLabel={label}
      style={{
        minHeight: 36,
        borderRadius: 18,
        paddingHorizontal: 13,
        alignItems: "center",
        justifyContent: "center",
        backgroundColor: selected ? apple.colors.cyan : "rgba(255,255,255,0.1)",
        borderWidth: 1,
        borderColor: selected ? "rgba(255,255,255,0.35)" : "rgba(255,255,255,0.12)",
      }}
    >
      <Text
        style={{
          color: selected ? "#061016" : apple.colors.label,
          fontSize: 13,
          fontWeight: "900",
        }}
        numberOfLines={1}
      >
        {label}
      </Text>
    </ApplePressable>
  );
}
