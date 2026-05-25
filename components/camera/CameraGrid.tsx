import { View, ScrollView, Text, Image, RefreshControl, Dimensions } from "react-native";
import { CameraCard } from "./CameraCard";
import { Skeleton } from "@/components/ui/Skeleton";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { FrigateConfig } from "@/types/camera";

type CameraGridProps = {
  onCameraPress: (name: string) => void;
  displayNames?: Record<string, string>;
};

const { width: SCREEN_WIDTH } = Dimensions.get("window");
const IS_TABLET = SCREEN_WIDTH >= 768;
const COLS = IS_TABLET ? 3 : 2;
const GAP = 12;
const PADDING = 16;
const CARD_WIDTH = (SCREEN_WIDTH - PADDING * 2 - GAP * (COLS - 1)) / COLS;

export function CameraGrid({ onCameraPress, displayNames = {} }: CameraGridProps) {
  const { data: config, isLoading, mutate } = useFrigateApi<FrigateConfig>("/config");

  const cameras = config ? Object.keys(config.cameras).filter(
    (name) => config.cameras[name].enabled !== false
  ) : [];

  if (isLoading) {
    return (
      <ScrollView className="flex-1 bg-background" contentContainerClassName="p-4">
        <View className="flex-row flex-wrap gap-3">
          {[1, 2, 3, 4].map((i) => (
            <Skeleton key={i} width={CARD_WIDTH} height={CARD_WIDTH * 0.5625 + 36} borderRadius={12} />
          ))}
        </View>
      </ScrollView>
    );
  }

  if (!cameras.length) {
    return (
      <View className="flex-1 bg-background items-center justify-center">
        <Image
          source={require("@/assets/icon.png")}
          style={{ width: 90, height: 90, borderRadius: 20, marginBottom: 16, opacity: 0.75 }}
          resizeMode="cover"
        />
        <Text className="text-text-primary text-lg">No cameras found</Text>
        <Text className="text-text-secondary text-sm mt-2">Check your Frigate server URL</Text>
      </View>
    );
  }

  const rows: string[][] = [];
  for (let i = 0; i < cameras.length; i += COLS) {
    rows.push(cameras.slice(i, i + COLS));
  }

  return (
    <ScrollView
      className="flex-1 bg-background"
      contentContainerStyle={{ padding: PADDING }}
      refreshControl={
        <RefreshControl refreshing={isLoading} onRefresh={() => mutate()} tintColor="#00b4d8" />
      }
    >
      {rows.map((row, ri) => (
        <View key={ri} className="flex-row mb-3" style={{ gap: GAP }}>
          {row.map((name) => (
            <CameraCard
              key={name}
              name={name}
              displayName={displayNames[name]}
              onPress={() => onCameraPress(name)}
              width={CARD_WIDTH}
            />
          ))}
        </View>
      ))}
    </ScrollView>
  );
}
