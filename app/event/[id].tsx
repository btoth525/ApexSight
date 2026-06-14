import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ActivityIndicator,
  Image,
  Linking,
  ScrollView,
  Text,
  View,
} from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { AppleMaterial, ApplePressable, apple } from "@/components/AppleMaterial";
import { useAuthStore } from "@/stores/authStore";
import { pendingDeeplink } from "@/stores/pendingDeeplink";
import { apiClient } from "@/utils/apiClient";
import { apiImageUrl, apiMediaUrl, mediaHeaders } from "@/utils/frigateMedia";
import type { FrigateEvent } from "@/utils/frigateTypes";
import { haptic } from "@/utils/haptics";
import { formatLabel, getLabelEmoji } from "@/utils/labelUtil";

function titleize(value?: string | null) {
  return (value ?? "").replace(/_/g, " ").replace(/\b\w/g, (char) => char.toUpperCase());
}

function timeText(epoch?: number) {
  if (!epoch) return "Live";
  return new Date(epoch * 1000).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function pct(value?: number) {
  if (value === undefined) return null;
  return `${Math.round(value * 100)}%`;
}

export default function EventDetailScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { id, camera, label, score, start } = useLocalSearchParams<{
    id: string;
    camera?: string;
    label?: string;
    score?: string;
    start?: string;
  }>();
  const { baseUrl, token } = useAuthStore();
  const headers = useMemo(() => mediaHeaders(token), [token]);
  const [event, setEvent] = useState<FrigateEvent | null>(() => ({
    id,
    camera: camera ?? "",
    label: label ?? "event",
    score: score ? Number(score) : undefined,
    start_time: start ? Number(start) : undefined,
  }));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError("");
    apiClient.get<FrigateEvent>(`/events/${id}`)
      .then((result) => {
        if (mounted && result.data?.id) setEvent(result.data);
      })
      .catch(() => {
        if (mounted) setError("Full event details are not available from this Frigate server.");
      })
      .finally(() => {
        if (mounted) setLoading(false);
      });
    return () => {
      mounted = false;
    };
  }, [id]);

  const snapshotUrl = useMemo(
    () => apiImageUrl(baseUrl, `events/${id}/snapshot.jpg`, { crop: 1, bbox: 1, quality: 95 }),
    [baseUrl, id],
  );
  const cleanCamera = titleize(event?.camera || camera);
  const cleanLabel = formatLabel(event?.label || label || "Event");
  const confidence = pct(event?.top_score ?? event?.score);
  const hasClip = event?.has_clip !== false;

  const openClip = useCallback(() => {
    haptic.tap();
    Linking.openURL(apiMediaUrl(baseUrl, `events/${id}/clip.mp4`)).catch(() => {});
  }, [baseUrl, id]);

  const openWebReview = useCallback(() => {
    haptic.tap();
    pendingDeeplink.set(`apex:///review?id=${encodeURIComponent(id)}`);
    router.push("/browser");
  }, [id, router]);

  return (
    <View style={{ flex: 1, backgroundColor: apple.colors.background }}>
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={{
          paddingTop: insets.top + 14,
          paddingBottom: insets.bottom + 28,
          paddingHorizontal: 18,
          gap: 16,
        }}
      >
        <View style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
          <ApplePressable
            onPress={() => {
              haptic.tap();
              router.back();
            }}
            accessibilityLabel="Back"
            style={{
              width: 44,
              height: 44,
              borderRadius: 22,
              alignItems: "center",
              justifyContent: "center",
              backgroundColor: "rgba(255,255,255,0.12)",
            }}
          >
            <Ionicons name="chevron-back" size={22} color={apple.colors.label} />
          </ApplePressable>
          <View style={{ flex: 1 }}>
            <Text style={{ color: apple.colors.label, fontSize: 28, fontWeight: "900" }} numberOfLines={1}>
              {getLabelEmoji(event?.label || label || "")} {cleanLabel}
            </Text>
            <Text style={{ color: apple.colors.secondaryLabel, fontSize: 13, fontWeight: "700", marginTop: 2 }} numberOfLines={1}>
              {cleanCamera || "Camera"} - {timeText(event?.start_time)}
            </Text>
          </View>
        </View>

        <AppleMaterial tint="systemChromeMaterialDark" intensity={88} contentStyle={{ padding: 10 }}>
          <Image
            source={{ uri: snapshotUrl, headers }}
            style={{ width: "100%", aspectRatio: 16 / 10, borderRadius: 20, backgroundColor: "#101014" }}
            resizeMode="cover"
          />
        </AppleMaterial>

        <AppleMaterial tint="systemMaterialDark" intensity={88} contentStyle={{ padding: 16, gap: 14 }}>
          <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 12 }}>
            <View style={{ flex: 1 }}>
              <Text style={{ color: apple.colors.label, fontSize: 20, fontWeight: "900" }}>Event Details</Text>
              <Text style={{ color: apple.colors.secondaryLabel, fontSize: 13, fontWeight: "700", marginTop: 2 }}>
                Native Frigate alert review
              </Text>
            </View>
            {loading ? <ActivityIndicator color={apple.colors.cyan} /> : null}
          </View>

          {error ? (
            <Text style={{ color: apple.colors.orange, fontSize: 13, fontWeight: "700", lineHeight: 18 }}>{error}</Text>
          ) : null}

          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 10 }}>
            {confidence ? <Metric icon="speedometer-outline" label="Confidence" value={confidence} /> : null}
            <Metric icon="videocam-outline" label="Camera" value={cleanCamera || "Camera"} />
            <Metric icon="time-outline" label="Started" value={timeText(event?.start_time)} />
            {event?.end_time ? <Metric icon="checkmark-circle-outline" label="Ended" value={timeText(event.end_time)} /> : null}
          </View>

          {event?.zones?.length ? (
            <View style={{ gap: 8 }}>
              <Text style={{ color: apple.colors.secondaryLabel, fontSize: 12, fontWeight: "800", textTransform: "uppercase" }}>
                Zones
              </Text>
              <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8 }}>
                {event.zones.map((zone) => (
                  <View
                    key={zone}
                    style={{
                      borderRadius: 999,
                      paddingHorizontal: 12,
                      paddingVertical: 8,
                      backgroundColor: "rgba(100,210,255,0.14)",
                      borderWidth: 1,
                      borderColor: "rgba(100,210,255,0.24)",
                    }}
                  >
                    <Text style={{ color: apple.colors.cyan, fontSize: 12, fontWeight: "900" }}>{titleize(zone)}</Text>
                  </View>
                ))}
              </View>
            </View>
          ) : null}
        </AppleMaterial>

        <View style={{ flexDirection: "row", gap: 10 }}>
          <ApplePressable
            onPress={openClip}
            disabled={!hasClip}
            accessibilityLabel="Open event clip"
            style={{
              flex: 1,
              borderRadius: 18,
              paddingVertical: 14,
              alignItems: "center",
              justifyContent: "center",
              backgroundColor: hasClip ? apple.colors.blue : "rgba(255,255,255,0.1)",
            }}
          >
            <Ionicons name="film-outline" size={19} color="#ffffff" />
            <Text style={{ color: "#ffffff", fontSize: 13, fontWeight: "900", marginTop: 5 }}>Clip</Text>
          </ApplePressable>
          <ApplePressable
            onPress={openWebReview}
            accessibilityLabel="Open event in Frigate"
            style={{
              flex: 1,
              borderRadius: 18,
              paddingVertical: 14,
              alignItems: "center",
              justifyContent: "center",
              backgroundColor: "rgba(255,255,255,0.12)",
            }}
          >
            <Ionicons name="albums-outline" size={19} color={apple.colors.label} />
            <Text style={{ color: apple.colors.label, fontSize: 13, fontWeight: "900", marginTop: 5 }}>Review</Text>
          </ApplePressable>
        </View>
      </ScrollView>
    </View>
  );
}

function Metric({ icon, label, value }: { icon: keyof typeof Ionicons.glyphMap; label: string; value: string }) {
  return (
    <View
      style={{
        minWidth: "47%",
        flexGrow: 1,
        borderRadius: 18,
        padding: 12,
        gap: 8,
        backgroundColor: "rgba(255,255,255,0.07)",
        borderWidth: 1,
        borderColor: "rgba(255,255,255,0.1)",
      }}
    >
      <Ionicons name={icon} size={18} color={apple.colors.cyan} />
      <Text style={{ color: apple.colors.secondaryLabel, fontSize: 11, fontWeight: "800", textTransform: "uppercase" }}>
        {label}
      </Text>
      <Text style={{ color: apple.colors.label, fontSize: 15, fontWeight: "900" }} numberOfLines={1}>
        {value}
      </Text>
    </View>
  );
}
