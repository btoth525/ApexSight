import { useState, useCallback } from "react";
import { View, Modal, FlatList, Dimensions, TouchableOpacity, Text, StatusBar } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRouter, useLocalSearchParams } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { CameraGrid } from "@/components/camera/CameraGrid";
import { LivePlayer } from "@/components/camera/LivePlayer";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { FrigateConfig } from "@/types/camera";
import { useSettingsStore } from "@/stores/settingsStore";
import { haptic } from "@/utils/haptics";

const { width: SCREEN_WIDTH } = Dimensions.get("window");

export default function LiveScreen() {
  const router = useRouter();
  const params = useLocalSearchParams<{ camera?: string }>();
  const [selectedCamera, setSelectedCamera] = useState<string | null>(params.camera ?? null);
  const [fullscreenCameraIndex, setFullscreenCameraIndex] = useState(0);
  const [showFullscreen, setShowFullscreen] = useState(false);

  const { data: config } = useFrigateApi<FrigateConfig>("/config");
  const { cameraDisplayNames } = useSettingsStore();

  const cameras = config ? Object.keys(config.cameras).filter(
    (n) => config.cameras[n].enabled !== false
  ) : [];

  const openFullscreen = useCallback((name: string) => {
    haptic.medium();
    const idx = cameras.indexOf(name);
    setFullscreenCameraIndex(idx >= 0 ? idx : 0);
    setSelectedCamera(name);
    setShowFullscreen(true);
  }, [cameras]);

  const closeFullscreen = useCallback(() => {
    haptic.tap();
    setShowFullscreen(false);
    setSelectedCamera(null);
  }, []);

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: "#0a0f1e" }} edges={["top"]}>
      <StatusBar barStyle="light-content" />
      {/* Header */}
      <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 16, paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: "#1e293b" }}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
          <Ionicons name="videocam" size={20} color="#00d4ff" />
          <Text style={{ color: "#f1f5f9", fontSize: 20, fontWeight: "700", letterSpacing: -0.3 }}>Live</Text>
        </View>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
          {cameras.length > 0 && (
            <View style={{ flexDirection: "row", alignItems: "center", gap: 5, backgroundColor: "#1e293b", borderRadius: 99, paddingHorizontal: 10, paddingVertical: 4 }}>
              <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: "#ef4444" }} />
              <Text style={{ color: "#94a3b8", fontSize: 12, fontWeight: "600" }}>{cameras.length} cameras</Text>
            </View>
          )}
          <TouchableOpacity
            onPress={() => { haptic.tap(); router.push("/camera-tour"); }}
            style={{ backgroundColor: "#1e293b", borderRadius: 8, padding: 7 }}
          >
            <Ionicons name="play-circle-outline" size={18} color="#00d4ff" />
          </TouchableOpacity>
        </View>
      </View>

      <CameraGrid onCameraPress={openFullscreen} displayNames={cameraDisplayNames} />

      <Modal
        visible={showFullscreen}
        animationType="fade"
        supportedOrientations={["portrait", "landscape"]}
        onRequestClose={closeFullscreen}
      >
        <View style={{ flex: 1, backgroundColor: "#000" }}>
          <FlatList
            data={cameras}
            keyExtractor={(item) => item}
            horizontal
            pagingEnabled
            initialScrollIndex={fullscreenCameraIndex}
            getItemLayout={(_, index) => ({ length: SCREEN_WIDTH, offset: SCREEN_WIDTH * index, index })}
            showsHorizontalScrollIndicator={false}
            renderItem={({ item }) => (
              <View style={{ width: SCREEN_WIDTH, flex: 1, justifyContent: "center" }}>
                <LivePlayer cameraName={item} isFullscreen onClose={closeFullscreen} />
              </View>
            )}
          />
        </View>
      </Modal>
    </SafeAreaView>
  );
}
