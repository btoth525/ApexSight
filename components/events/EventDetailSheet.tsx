import { useRef, useCallback, useEffect } from "react";
import { View, Text, TouchableOpacity, ScrollView, Share, Alert, Dimensions } from "react-native";
import BottomSheet, { BottomSheetScrollView } from "@gorhom/bottom-sheet";
import { VideoView, useVideoPlayer } from "expo-video";
import * as ExpoSharing from "expo-sharing";
import { useAuthStore } from "@/stores/authStore";
import { apiClient } from "@/utils/apiClient";
import { ReviewItem, FrigateEvent } from "@/types/event";
import { getLabelEmoji, formatLabel } from "@/utils/labelUtil";
import { formatRelativeTime, formatDuration, formatTimestamp } from "@/utils/timeUtil";
import { haptic } from "@/utils/haptics";

type EventDetailSheetProps = {
  event: ReviewItem | FrigateEvent | null;
  onClose: () => void;
  onReviewed?: () => void;
  onOpenExplore?: (eventId: string) => void;
};

function isReviewItem(e: ReviewItem | FrigateEvent): e is ReviewItem {
  return "severity" in e;
}

export function EventDetailSheet({ event, onClose, onReviewed, onOpenExplore }: EventDetailSheetProps) {
  const { baseUrl, token } = useAuthStore();
  const sheetRef = useRef<BottomSheet>(null);
  const snapPoints = ["50%", "92%"];

  const camera = event?.camera ?? "";
  const label = isReviewItem(event!) ? (event.data?.objects?.[0] ?? "motion") : (event as FrigateEvent).label;
  const startTime = event?.start_time ?? 0;
  const endTime = event?.end_time ?? null;
  const eventId = isReviewItem(event!) ? event.data?.detections?.[0] : (event as FrigateEvent).id;
  const hasClip = isReviewItem(event!) ? true : (event as FrigateEvent).has_clip;

  const clipUrl = eventId ? `${baseUrl}/api/events/${eventId}/clip.mp4` : null;
  const snapshotUrl = eventId ? `${baseUrl}/api/events/${eventId}/snapshot.jpg` : null;

  const player = useVideoPlayer(hasClip && clipUrl ? clipUrl : "", (p) => {
    p.loop = false;
    p.muted = false;
  });

  useEffect(() => {
    if (event) {
      sheetRef.current?.expand();
    } else {
      sheetRef.current?.close();
    }
  }, [event]);

  const handleMarkReviewed = useCallback(async () => {
    if (!event) return;
    try {
      const id = isReviewItem(event) ? event.id : event.id;
      await apiClient.post("/reviews/viewed", { ids: [id] });
      haptic.success();
      onReviewed?.();
      onClose();
    } catch {
      haptic.error();
      Alert.alert("Error", "Could not mark as reviewed.");
    }
  }, [event, onReviewed, onClose]);

  const handleShare = useCallback(async () => {
    haptic.medium();
    // Share the clip URL if available, otherwise snapshot
    const shareUrl = clipUrl ?? snapshotUrl;
    if (!shareUrl) return;
    const canShare = await ExpoSharing.isAvailableAsync();
    if (canShare) {
      await Share.share({ url: shareUrl, message: `${formatLabel(label)} detected on ${camera}` });
    } else {
      await Share.share({ message: `${formatLabel(label)} on ${camera}: ${shareUrl}` });
    }
  }, [clipUrl, snapshotUrl, label, camera]);

  const duration = startTime && endTime ? endTime - startTime : null;

  if (!event) return null;

  return (
    <BottomSheet
      ref={sheetRef}
      snapPoints={snapPoints}
      enablePanDownToClose
      onClose={onClose}
      backgroundStyle={{ backgroundColor: "#1e293b" }}
      handleIndicatorStyle={{ backgroundColor: "#475569" }}
    >
      <BottomSheetScrollView contentContainerStyle={{ paddingBottom: 40 }}>
        {/* Video / snapshot */}
        <View className="mx-4 rounded-xl overflow-hidden bg-black" style={{ height: 200 }}>
          {hasClip && clipUrl ? (
            <VideoView
              player={player}
              style={{ flex: 1 }}
              nativeControls
              contentFit="contain"
            />
          ) : snapshotUrl ? (
            <View className="flex-1 items-center justify-center">
              <Text className="text-text-secondary text-sm">No clip available</Text>
            </View>
          ) : null}
        </View>

        {/* Info */}
        <View className="mx-4 mt-4">
          <View className="flex-row items-center gap-2 mb-1">
            <Text className="text-2xl">{getLabelEmoji(label)}</Text>
            <Text className="text-text-primary text-xl font-bold">{formatLabel(label)}</Text>
            {isReviewItem(event) && (
              <View className={`px-2 py-0.5 rounded-full ${event.severity === "alert" ? "bg-red-500/20" : "bg-yellow-500/20"}`}>
                <Text className={`text-xs font-medium ${event.severity === "alert" ? "text-red-400" : "text-yellow-400"}`}>
                  {event.severity}
                </Text>
              </View>
            )}
          </View>

          <Text className="text-text-secondary text-sm mb-1">📷 {camera}</Text>
          <Text className="text-text-secondary text-sm mb-1">🕐 {formatTimestamp(startTime)}</Text>
          {duration !== null && (
            <Text className="text-text-secondary text-sm mb-1">⏱ {formatDuration(duration)}</Text>
          )}
          {isReviewItem(event) && event.data?.zones?.length > 0 && (
            <Text className="text-text-secondary text-sm">📍 {event.data.zones.join(", ")}</Text>
          )}
        </View>

        {/* Action buttons */}
        <View className="mx-4 mt-6 gap-3">
          <TouchableOpacity
            className="bg-primary rounded-xl py-3.5 items-center"
            onPress={handleMarkReviewed}
          >
            <Text className="text-white font-semibold">✓ Mark as Reviewed</Text>
          </TouchableOpacity>

          <View className="flex-row gap-3">
            <TouchableOpacity
              className="flex-1 bg-surface-2 rounded-xl py-3.5 items-center"
              onPress={handleShare}
            >
              <Text className="text-text-primary font-medium">↑ Share {clipUrl ? "Clip" : "Snapshot"}</Text>
            </TouchableOpacity>

            {onOpenExplore && eventId && (
              <TouchableOpacity
                className="flex-1 bg-surface-2 rounded-xl py-3.5 items-center"
                onPress={() => { haptic.tap(); onOpenExplore(eventId); onClose(); }}
              >
                <Text className="text-text-primary font-medium">🔍 Explore</Text>
              </TouchableOpacity>
            )}
          </View>

          <TouchableOpacity
            className="bg-surface rounded-xl py-3.5 items-center border border-border"
            onPress={() => { haptic.tap(); onClose(); }}
          >
            <Text className="text-text-secondary font-medium">Close</Text>
          </TouchableOpacity>
        </View>
      </BottomSheetScrollView>
    </BottomSheet>
  );
}
