import { ActivityIndicator, Image, Text, View } from "react-native";
import { AppleMaterial, apple } from "@/components/AppleMaterial";

export default function Index() {
  return (
    <View
      style={{
        flex: 1,
        backgroundColor: apple.colors.background,
        alignItems: "center",
        justifyContent: "center",
        padding: 28,
      }}
    >
      <AppleMaterial
        tint="systemChromeMaterialDark"
        intensity={86}
        style={{ borderRadius: 30 }}
        contentStyle={{ padding: 24, alignItems: "center", gap: 14, minWidth: 190 }}
      >
        <Image
          source={require("@/assets/icon.png")}
          style={{ width: 70, height: 70, borderRadius: 18 }}
          resizeMode="cover"
        />
        <View style={{ alignItems: "center", gap: 4 }}>
          <Text style={{ color: apple.colors.label, fontSize: 20, fontWeight: "800" }}>Apex</Text>
          <Text style={{ color: apple.colors.secondaryLabel, fontSize: 12, fontWeight: "600" }}>
            Preparing cameras
          </Text>
        </View>
        <ActivityIndicator color={apple.colors.cyan} />
      </AppleMaterial>
    </View>
  );
}
