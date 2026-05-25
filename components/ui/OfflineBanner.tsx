import { useEffect, useState } from "react";
import { View, Text, Animated } from "react-native";
import NetInfo from "@react-native-community/netinfo";

export function OfflineBanner() {
  const [isOffline, setIsOffline] = useState(false);
  const [wasOffline, setWasOffline] = useState(false);
  const [showBack, setShowBack] = useState(false);
  const opacity = useState(new Animated.Value(0))[0];

  useEffect(() => {
    const unsub = NetInfo.addEventListener((state) => {
      const offline = !state.isConnected;
      setIsOffline(offline);
      if (offline) {
        setWasOffline(true);
        setShowBack(false);
      } else if (wasOffline) {
        setShowBack(true);
        setTimeout(() => { setShowBack(false); setWasOffline(false); }, 3000);
      }
    });
    return unsub;
  }, [wasOffline]);

  const visible = isOffline || showBack;

  useEffect(() => {
    Animated.timing(opacity, {
      toValue: visible ? 1 : 0,
      duration: 300,
      useNativeDriver: true,
    }).start();
  }, [visible]);

  if (!visible) return null;

  return (
    <Animated.View style={{ opacity, backgroundColor: isOffline ? "#7f1d1d" : "#14532d", paddingVertical: 6, alignItems: "center" }}>
      <Text style={{ color: "#fff", fontSize: 12, fontWeight: "600" }}>
        {isOffline ? "⚠ No network connection" : "✓ Back online"}
      </Text>
    </Animated.View>
  );
}
