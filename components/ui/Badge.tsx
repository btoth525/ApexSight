import { View, Text } from "react-native";

type BadgeProps = {
  label: string;
  color?: string;
  size?: "sm" | "md";
};

export function Badge({ label, color = "#64748b", size = "sm" }: BadgeProps) {
  const padding = size === "sm" ? "px-2 py-0.5" : "px-3 py-1";
  const textSize = size === "sm" ? "text-xs" : "text-sm";
  return (
    <View
      className={`${padding} rounded-full`}
      style={{ backgroundColor: color + "33" }}
    >
      <Text className={`${textSize} font-medium`} style={{ color }}>
        {label}
      </Text>
    </View>
  );
}
