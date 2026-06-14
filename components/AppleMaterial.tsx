import type React from "react";
import { Pressable, StyleSheet, Text, type TextStyle, View, type ViewStyle } from "react-native";
import { BlurView, type BlurTint } from "expo-blur";

export const apple = {
  colors: {
    background: "#050507",
    label: "#f5f5f7",
    secondaryLabel: "rgba(235,235,245,0.62)",
    tertiaryLabel: "rgba(235,235,245,0.38)",
    separator: "rgba(84,84,88,0.42)",
    blue: "#0a84ff",
    cyan: "#64d2ff",
    green: "#30d158",
    orange: "#ff9f0a",
    red: "#ff453a",
  },
  radius: {
    card: 28,
    control: 18,
    pill: 999,
  },
};

type MaterialProps = {
  children: React.ReactNode;
  style?: ViewStyle;
  contentStyle?: ViewStyle;
  tint?: BlurTint;
  intensity?: number;
};

export function AppleMaterial({
  children,
  style,
  contentStyle,
  tint = "systemChromeMaterialDark",
  intensity = 84,
}: MaterialProps) {
  return (
    <BlurView tint={tint} intensity={intensity} style={[styles.material, style]}>
      <View style={[styles.materialContent, contentStyle]}>{children}</View>
    </BlurView>
  );
}

type ApplePressableProps = {
  children: React.ReactNode;
  onPress?: () => void;
  disabled?: boolean;
  style?: ViewStyle;
  pressedStyle?: ViewStyle;
  accessibilityLabel?: string;
};

export function ApplePressable({
  children,
  onPress,
  disabled,
  style,
  pressedStyle,
  accessibilityLabel,
}: ApplePressableProps) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.pressable,
        style,
        pressed && !disabled ? styles.pressed : null,
        pressed && !disabled ? pressedStyle : null,
        disabled ? styles.disabled : null,
      ]}
    >
      {children}
    </Pressable>
  );
}

type AppleTextProps = {
  children: React.ReactNode;
  style?: TextStyle;
  numberOfLines?: number;
};

export function AppleTitle({ children, style, numberOfLines }: AppleTextProps) {
  return (
    <Text numberOfLines={numberOfLines} style={[styles.title, style]}>
      {children}
    </Text>
  );
}

export function AppleCaption({ children, style, numberOfLines }: AppleTextProps) {
  return (
    <Text numberOfLines={numberOfLines} style={[styles.caption, style]}>
      {children}
    </Text>
  );
}

const styles = StyleSheet.create({
  material: {
    overflow: "hidden",
    borderRadius: apple.radius.card,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "rgba(255,255,255,0.18)",
  },
  materialContent: {
    backgroundColor: "rgba(255,255,255,0.045)",
  },
  pressable: {
    transform: [{ scale: 1 }],
  },
  pressed: {
    opacity: 0.72,
    transform: [{ scale: 0.985 }],
  },
  disabled: {
    opacity: 0.55,
  },
  title: {
    color: apple.colors.label,
    fontSize: 34,
    fontWeight: "800",
  },
  caption: {
    color: apple.colors.secondaryLabel,
    fontSize: 13,
    fontWeight: "600",
  },
});
