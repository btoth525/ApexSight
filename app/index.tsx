import { View, ActivityIndicator } from "react-native";

export default function Index() {
  return (
    <View style={{ flex: 1, backgroundColor: "#000000", alignItems: "center", justifyContent: "center" }}>
      <ActivityIndicator color="#00d4ff" size="large" />
    </View>
  );
}
