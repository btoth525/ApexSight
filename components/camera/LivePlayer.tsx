import { useRef, useState, useCallback } from "react";
import { View, Text, TouchableOpacity, Dimensions, StyleSheet, Platform } from "react-native";
import { VideoView, useVideoPlayer } from "expo-video";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { activateKeepAwakeAsync, deactivateKeepAwake } from "expo-keep-awake";
import * as ScreenOrientation from "expo-screen-orientation";
import { GestureDetector, Gesture } from "react-native-gesture-handler";
import Animated, {
  useSharedValue, useAnimatedStyle, withSpring, clamp,
} from "react-native-reanimated";
import { useAuthStore } from "@/stores/authStore";
import { haptic } from "@/utils/haptics";

type LivePlayerProps = {
  cameraName: string;
  onClose?: () => void;
  isFullscreen?: boolean;
};

export function LivePlayer({ cameraName, onClose, isFullscreen = false }: LivePlayerProps) {
  const { baseUrl, token } = useAuthStore();
  const insets = useSafeAreaInsets();
  const streamUrl = `${baseUrl}/api/${cameraName}/stream.m3u8`;
  const [controlsVisible, setControlsVisible] = useState(true);
  const controlsTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const scale = useSharedValue(1);
  const savedScale = useSharedValue(1);

  const source = token && token !== "session"
    ? { uri: streamUrl, headers: { Cookie: `frigate_token=${token}`, "X-CSRF-TOKEN": "1" } }
    : streamUrl;

  const player = useVideoPlayer(source, (p) => {
    p.loop = true;
    p.muted = false;
    p.play();
  });

  const showControls = useCallback(() => {
    setControlsVisible(true);
    if (controlsTimer.current) clearTimeout(controlsTimer.current);
    controlsTimer.current = setTimeout(() => setControlsVisible(false), 4000);
  }, []);

  const enterFullscreen = useCallback(async () => {
    haptic.medium();
    await ScreenOrientation.lockAsync(ScreenOrientation.OrientationLock.LANDSCAPE);
    await activateKeepAwakeAsync("live-player");
  }, []);

  const exitFullscreen = useCallback(async () => {
    haptic.tap();
    await ScreenOrientation.unlockAsync();
    deactivateKeepAwake("live-player");
    onClose?.();
  }, [onClose]);

  const pinchGesture = Gesture.Pinch()
    .onUpdate((e) => { scale.value = clamp(savedScale.value * e.scale, 1, 4); })
    .onEnd(() => {
      savedScale.value = scale.value;
      if (scale.value < 1.05) { scale.value = withSpring(1); savedScale.value = 1; }
    });

  const doubleTapGesture = Gesture.Tap()
    .numberOfTaps(2)
    .onEnd(() => { scale.value = withSpring(1); savedScale.value = 1; });

  const tapGesture = Gesture.Tap()
    .numberOfTaps(1)
    .onEnd(() => showControls());

  const composed = Gesture.Race(doubleTapGesture, Gesture.Simultaneous(pinchGesture, tapGesture));
  const animatedStyle = useAnimatedStyle(() => ({ transform: [{ scale: scale.value }] }));

  const { width, height } = Dimensions.get("window");
  const playerWidth = isFullscreen ? Math.max(width, height) : width;
  const playerHeight = isFullscreen ? Math.min(width, height) : (width * 9) / 16;

  // Safe area top padding — critical for notch/Dynamic Island
  const topPad = isFullscreen ? insets.top : 0;

  return (
    <View style={[styles.container, { width: playerWidth, height: playerHeight }]}>
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

      {controlsVisible && (
        <View style={StyleSheet.absoluteFillObject}>
          {/* Top bar — padded for notch */}
          <View style={[styles.topBar, { paddingTop: topPad + 8 }]}>
            {onClose && (
              <TouchableOpacity
                onPress={exitFullscreen}
                style={styles.controlBtn}
                hitSlop={{ top: 12, bottom: 12, left: 12, right: 12 }}
              >
                <Text style={styles.controlBtnText}>✕</Text>
              </TouchableOpacity>
            )}
            <Text style={styles.cameraTitle} numberOfLines={1}>
              {cameraName.replace(/_/g, " ")}
            </Text>
            <TouchableOpacity
              onPress={() => player.enterPictureInPicture?.()}
              style={styles.controlBtn}
              hitSlop={{ top: 12, bottom: 12, left: 12, right: 12 }}
            >
              <Text style={styles.controlBtnText}>⧉</Text>
            </TouchableOpacity>
          </View>

          {/* Bottom bar */}
          <View style={[styles.bottomBar, { paddingBottom: isFullscreen ? insets.bottom + 8 : 12 }]}>
            <View style={styles.liveBadge}>
              <View style={styles.liveDot} />
              <Text style={styles.liveText}>LIVE</Text>
            </View>
            {!isFullscreen && (
              <TouchableOpacity onPress={enterFullscreen} style={styles.fsBtn}>
                <Text style={styles.fsBtnText}>⛶  Fullscreen</Text>
              </TouchableOpacity>
            )}
          </View>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { backgroundColor: "#000", overflow: "hidden" },
  topBar: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingBottom: 16,
    backgroundColor: "rgba(0,0,0,0.55)",
  },
  controlBtn: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: "rgba(255,255,255,0.15)",
    alignItems: "center",
    justifyContent: "center",
  },
  controlBtnText: { color: "#fff", fontSize: 16, fontWeight: "600" },
  cameraTitle: {
    flex: 1,
    color: "#fff",
    fontWeight: "700",
    fontSize: 17,
    textAlign: "center",
    textTransform: "capitalize",
    letterSpacing: 0.3,
    marginHorizontal: 8,
  },
  bottomBar: {
    position: "absolute",
    bottom: 0,
    left: 16,
    right: 16,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  liveBadge: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: "rgba(0,0,0,0.65)",
    borderRadius: 99,
    paddingHorizontal: 10,
    paddingVertical: 4,
    gap: 6,
  },
  liveDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: "#ef4444" },
  liveText: { color: "#fff", fontSize: 11, fontWeight: "700", letterSpacing: 1 },
  fsBtn: {
    backgroundColor: "rgba(0,0,0,0.65)",
    borderRadius: 99,
    paddingHorizontal: 12,
    paddingVertical: 4,
  },
  fsBtnText: { color: "#fff", fontSize: 12, fontWeight: "600" },
});
