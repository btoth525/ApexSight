import { useRef, useState, useCallback } from "react";
import { View, Text, TouchableOpacity, Dimensions, StyleSheet } from "react-native";
import { VideoView, useVideoPlayer } from "expo-video";
import { activateKeepAwakeAsync, deactivateKeepAwake } from "expo-keep-awake";
import * as ScreenOrientation from "expo-screen-orientation";
import { GestureDetector, Gesture } from "react-native-gesture-handler";
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  clamp,
} from "react-native-reanimated";
import { useAuthStore } from "@/stores/authStore";

type LivePlayerProps = {
  cameraName: string;
  onClose?: () => void;
  isFullscreen?: boolean;
};

export function LivePlayer({ cameraName, onClose, isFullscreen = false }: LivePlayerProps) {
  const { baseUrl } = useAuthStore();
  const streamUrl = `${baseUrl}/api/${cameraName}/stream.m3u8`;
  const [controlsVisible, setControlsVisible] = useState(true);
  const controlsTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const scale = useSharedValue(1);
  const savedScale = useSharedValue(1);

  const player = useVideoPlayer(streamUrl, (p) => {
    p.loop = true;
    p.muted = true;
    p.play();
  });

  const showControls = useCallback(() => {
    setControlsVisible(true);
    if (controlsTimer.current) clearTimeout(controlsTimer.current);
    controlsTimer.current = setTimeout(() => setControlsVisible(false), 3000);
  }, []);

  const enterFullscreen = useCallback(async () => {
    await ScreenOrientation.lockAsync(ScreenOrientation.OrientationLock.LANDSCAPE);
    await activateKeepAwakeAsync("live-player");
  }, []);

  const exitFullscreen = useCallback(async () => {
    await ScreenOrientation.unlockAsync();
    deactivateKeepAwake("live-player");
    onClose?.();
  }, [onClose]);

  const pinchGesture = Gesture.Pinch()
    .onUpdate((e) => {
      scale.value = clamp(savedScale.value * e.scale, 1, 4);
    })
    .onEnd(() => {
      savedScale.value = scale.value;
      if (scale.value < 1.05) {
        scale.value = withSpring(1);
        savedScale.value = 1;
      }
    });

  const doubleTapGesture = Gesture.Tap()
    .numberOfTaps(2)
    .onEnd(() => {
      scale.value = withSpring(1);
      savedScale.value = 1;
    });

  const tapGesture = Gesture.Tap()
    .numberOfTaps(1)
    .onEnd(() => {
      showControls();
    });

  const composed = Gesture.Race(doubleTapGesture, Gesture.Simultaneous(pinchGesture, tapGesture));

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
  }));

  const { width, height } = Dimensions.get("window");
  const playerWidth = isFullscreen ? Math.max(width, height) : width;
  const playerHeight = isFullscreen ? Math.min(width, height) : (width * 9) / 16;

  return (
    <View style={[styles.container, { width: playerWidth, height: playerHeight }]} className="bg-black">
      <GestureDetector gesture={composed}>
        <Animated.View style={[{ flex: 1 }, animatedStyle]}>
          <VideoView
            player={player}
            style={{ flex: 1 }}
            nativeControls={false}
            contentFit="contain"
            allowsFullscreen={false}
          />
        </Animated.View>
      </GestureDetector>

      {/* Controls overlay */}
      {controlsVisible && (
        <View className="absolute inset-0">
          {/* Top bar */}
          <View className="flex-row items-center justify-between px-4 pt-4 bg-gradient-to-b from-black/60 to-transparent">
            {onClose && (
              <TouchableOpacity onPress={exitFullscreen} className="p-2">
                <Text className="text-white text-2xl">✕</Text>
              </TouchableOpacity>
            )}
            <Text className="text-white font-semibold text-lg flex-1 text-center">
              {cameraName}
            </Text>
            <TouchableOpacity
              onPress={() => player.enterPictureInPicture?.()}
              className="p-2"
            >
              <Text className="text-white text-xl">⧉</Text>
            </TouchableOpacity>
          </View>

          {/* Bottom bar */}
          <View className="absolute bottom-4 left-4 right-4 flex-row items-center justify-between">
            <View className="flex-row items-center gap-2 bg-black/60 rounded-full px-3 py-1">
              <View className="w-2 h-2 rounded-full bg-red-500" />
              <Text className="text-white text-sm font-medium">LIVE</Text>
            </View>
            {!isFullscreen && (
              <TouchableOpacity
                onPress={enterFullscreen}
                className="bg-black/60 rounded-full px-3 py-1"
              >
                <Text className="text-white text-sm">⛶ Fullscreen</Text>
              </TouchableOpacity>
            )}
          </View>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: "#000",
    overflow: "hidden",
  },
});
