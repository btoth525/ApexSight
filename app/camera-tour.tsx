import { useState, useEffect, useRef, useCallback } from "react";
import { View, Text, TouchableOpacity, Dimensions, FlatList } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRouter } from "expo-router";
import { activateKeepAwakeAsync, deactivateKeepAwake } from "expo-keep-awake";
import * as ScreenOrientation from "expo-screen-orientation";
import { LivePlayer } from "@/components/camera/LivePlayer";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { useFrigateEvents } from "@/hooks/useFrigateEvents";
import { FrigateConfig } from "@/types/camera";

const { width: SCREEN_WIDTH } = Dimensions.get("window");
const CYCLE_INTERVAL = 10000; // 10s per camera
const ALERT_DWELL = 15000;   // 15s on alert camera

export default function CameraTourScreen() {
  const router = useRouter();
  const { data: config } = useFrigateApi<FrigateConfig>("/config");
  const cameras = config ? Object.keys(config.cameras).filter(n => config.cameras[n].enabled !== false) : [];

  const [currentIndex, setCurrentIndex] = useState(0);
  const [paused, setPaused] = useState(false);
  const [alertInfo, setAlertInfo] = useState<{ camera: string; label: string } | null>(null);
  const flatListRef = useRef<FlatList>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const alertTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    activateKeepAwakeAsync("camera-tour");
    ScreenOrientation.lockAsync(ScreenOrientation.OrientationLock.LANDSCAPE);
    return () => {
      deactivateKeepAwake("camera-tour");
      ScreenOrientation.unlockAsync();
    };
  }, []);

  const goTo = useCallback((idx: number) => {
    const clamped = Math.max(0, Math.min(idx, cameras.length - 1));
    setCurrentIndex(clamped);
    flatListRef.current?.scrollToIndex({ index: clamped, animated: true });
  }, [cameras.length]);

  const advance = useCallback(() => {
    setCurrentIndex((prev) => {
      const next = (prev + 1) % Math.max(cameras.length, 1);
      flatListRef.current?.scrollToIndex({ index: next, animated: true });
      return next;
    });
  }, [cameras.length]);

  useEffect(() => {
    if (paused || cameras.length === 0) return;
    timerRef.current = setInterval(advance, CYCLE_INTERVAL);
    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [paused, cameras.length, advance]);

  useFrigateEvents(useCallback((data: unknown) => {
    const event = data as { type?: string; after?: { camera?: string; label?: string }; severity?: string };
    if (event.type === "reviews" || event.severity === "alert") {
      const camera = event.after?.camera;
      const label = event.after?.label ?? "Motion";
      if (camera && cameras.includes(camera)) {
        const idx = cameras.indexOf(camera);
        if (timerRef.current) clearInterval(timerRef.current);
        goTo(idx);
        setAlertInfo({ camera, label });
        setPaused(true);
        alertTimerRef.current = setTimeout(() => {
          setAlertInfo(null);
          setPaused(false);
        }, ALERT_DWELL);
      }
    }
  }, [cameras, goTo]));

  return (
    <View className="flex-1 bg-black">
      <FlatList
        ref={flatListRef}
        data={cameras}
        keyExtractor={(item) => item}
        horizontal
        pagingEnabled
        scrollEnabled={false}
        showsHorizontalScrollIndicator={false}
        getItemLayout={(_, index) => ({
          length: SCREEN_WIDTH,
          offset: SCREEN_WIDTH * index,
          index,
        })}
        renderItem={({ item }) => (
          <View style={{ width: SCREEN_WIDTH }}>
            <LivePlayer cameraName={item} isFullscreen />
          </View>
        )}
      />

      {/* Alert overlay */}
      {alertInfo && (
        <View className="absolute top-8 left-0 right-0 items-center">
          <View className="bg-red-500/90 rounded-2xl px-6 py-3">
            <Text className="text-white font-bold text-lg">
              ⚡ {alertInfo.label} detected — {alertInfo.camera}
            </Text>
          </View>
        </View>
      )}

      {/* Controls */}
      <View className="absolute bottom-6 left-0 right-0 flex-row items-center justify-center gap-4">
        <TouchableOpacity
          onPress={() => goTo(currentIndex - 1)}
          className="bg-black/60 rounded-full w-10 h-10 items-center justify-center"
        >
          <Text className="text-white text-xl">‹</Text>
        </TouchableOpacity>

        <TouchableOpacity
          onPress={() => setPaused((p) => !p)}
          className="bg-black/60 rounded-full w-10 h-10 items-center justify-center"
        >
          <Text className="text-white text-xl">{paused ? "▶" : "⏸"}</Text>
        </TouchableOpacity>

        <TouchableOpacity
          onPress={() => goTo(currentIndex + 1)}
          className="bg-black/60 rounded-full w-10 h-10 items-center justify-center"
        >
          <Text className="text-white text-xl">›</Text>
        </TouchableOpacity>

        <TouchableOpacity
          onPress={() => router.back()}
          className="bg-black/60 rounded-full w-10 h-10 items-center justify-center"
        >
          <Text className="text-white text-xl">✕</Text>
        </TouchableOpacity>
      </View>

      {/* Camera dots indicator */}
      <View className="absolute bottom-20 left-0 right-0 flex-row items-center justify-center gap-1.5">
        {cameras.map((_, i) => (
          <TouchableOpacity key={i} onPress={() => goTo(i)}>
            <View
              className={`rounded-full ${i === currentIndex ? "w-3 h-3 bg-primary" : "w-2 h-2 bg-white/40"}`}
            />
          </TouchableOpacity>
        ))}
      </View>
    </View>
  );
}
