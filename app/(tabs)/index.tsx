import { useState, useCallback } from "react";
import { View, Modal, FlatList, Dimensions, TouchableOpacity, Text } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useLocalSearchParams } from "expo-router";
import { CameraGrid } from "@/components/camera/CameraGrid";
import { LivePlayer } from "@/components/camera/LivePlayer";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { FrigateConfig } from "@/types/camera";
import { useSettingsStore } from "@/stores/settingsStore";

const { width: SCREEN_WIDTH } = Dimensions.get("window");

export default function LiveScreen() {
  const params = useLocalSearchParams<{ camera?: string }>();
  const [selectedCamera, setSelectedCamera] = useState<string | null>(
    params.camera ?? null
  );
  const [fullscreenCameraIndex, setFullscreenCameraIndex] = useState(0);
  const [showFullscreen, setShowFullscreen] = useState(false);

  const { data: config } = useFrigateApi<FrigateConfig>("/config");
  const { cameraDisplayNames } = useSettingsStore();

  const cameras = config ? Object.keys(config.cameras).filter(
    (n) => config.cameras[n].enabled !== false
  ) : [];

  const openFullscreen = useCallback((name: string) => {
    const idx = cameras.indexOf(name);
    setFullscreenCameraIndex(idx >= 0 ? idx : 0);
    setSelectedCamera(name);
    setShowFullscreen(true);
  }, [cameras]);

  const closeFullscreen = useCallback(() => {
    setShowFullscreen(false);
    setSelectedCamera(null);
  }, []);

  return (
    <SafeAreaView className="flex-1 bg-background" edges={["top"]}>
      {/* Header */}
      <View className="px-4 py-3 flex-row items-center justify-between border-b border-surface-2">
        <Text className="text-text-primary text-xl font-bold">Live</Text>
        <View className="flex-row items-center gap-2 bg-surface rounded-full px-3 py-1">
          <View className="w-2 h-2 rounded-full bg-red-500" />
          <Text className="text-text-secondary text-xs">{cameras.length} cameras</Text>
        </View>
      </View>

      <CameraGrid
        onCameraPress={openFullscreen}
        displayNames={cameraDisplayNames}
      />

      {/* Fullscreen player modal with swipe between cameras */}
      <Modal
        visible={showFullscreen}
        animationType="fade"
        supportedOrientations={["portrait", "landscape"]}
        onRequestClose={closeFullscreen}
      >
        <View className="flex-1 bg-black">
          <FlatList
            data={cameras}
            keyExtractor={(item) => item}
            horizontal
            pagingEnabled
            initialScrollIndex={fullscreenCameraIndex}
            getItemLayout={(_, index) => ({
              length: SCREEN_WIDTH,
              offset: SCREEN_WIDTH * index,
              index,
            })}
            showsHorizontalScrollIndicator={false}
            renderItem={({ item }) => (
              <View style={{ width: SCREEN_WIDTH }}>
                <LivePlayer
                  cameraName={item}
                  isFullscreen
                  onClose={closeFullscreen}
                />
              </View>
            )}
          />
        </View>
      </Modal>
    </SafeAreaView>
  );
}
