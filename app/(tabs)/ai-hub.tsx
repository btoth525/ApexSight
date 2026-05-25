import { useState } from "react";
import { View, Text, TouchableOpacity, StatusBar } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { Ionicons } from "@expo/vector-icons";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { GuardStatusCard } from "@/components/ai/GuardStatusCard";
import { InsightsTab } from "@/components/ai/InsightsTab";
import { TriggersTab } from "@/components/ai/TriggersTab";
import { GuardStatus } from "@/types/api";
import { haptic } from "@/utils/haptics";

type Tab = "insights" | "guard" | "triggers";

const TABS: { id: Tab; icon: React.ComponentProps<typeof Ionicons>["name"]; label: string }[] = [
  { id: "insights", icon: "stats-chart", label: "Insights" },
  { id: "guard",    icon: "shield",      label: "Guard" },
  { id: "triggers", icon: "flash",       label: "Triggers" },
];

export default function AIHubScreen() {
  const [activeTab, setActiveTab] = useState<Tab>("insights");
  const { data: guardStatus, mutate: mutateGuard } = useFrigateApi<GuardStatus>("/guard/status");

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaView style={{ flex: 1, backgroundColor: "#0a0f1e" }} edges={["top"]}>
        <StatusBar barStyle="light-content" />

        {/* Header */}
        <View style={{ paddingHorizontal: 16, paddingTop: 12, paddingBottom: 12, borderBottomWidth: 1, borderBottomColor: "#1e293b" }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 8, marginBottom: 12 }}>
            <Ionicons name="shield" size={20} color="#00d4ff" />
            <Text style={{ color: "#f1f5f9", fontSize: 20, fontWeight: "700", letterSpacing: -0.3 }}>AI Hub</Text>
            {guardStatus?.active && (
              <View style={{ flexDirection: "row", alignItems: "center", gap: 4, backgroundColor: "#00d4ff22", borderRadius: 99, paddingHorizontal: 8, paddingVertical: 2 }}>
                <View style={{ width: 5, height: 5, borderRadius: 3, backgroundColor: "#00d4ff" }} />
                <Text style={{ color: "#00d4ff", fontSize: 11, fontWeight: "700" }}>GUARDING</Text>
              </View>
            )}
          </View>

          {/* Tab selector */}
          <View style={{ flexDirection: "row", backgroundColor: "#1e293b", borderRadius: 12, padding: 3, gap: 2 }}>
            {TABS.map(({ id, icon, label }) => (
              <TouchableOpacity
                key={id}
                onPress={() => { haptic.tap(); setActiveTab(id); }}
                style={{ flex: 1, paddingVertical: 8, borderRadius: 10, alignItems: "center", flexDirection: "row", justifyContent: "center", gap: 5, backgroundColor: activeTab === id ? "#00d4ff" : "transparent" }}
              >
                <Ionicons name={icon} size={14} color={activeTab === id ? "#0a0f1e" : "#64748b"} />
                <Text style={{ fontSize: 13, fontWeight: "600", color: activeTab === id ? "#0a0f1e" : "#64748b" }}>{label}</Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        {activeTab === "guard" && (
          <View style={{ marginTop: 16, marginBottom: 8 }}>
            <GuardStatusCard status={guardStatus} onToggle={() => mutateGuard()} />
          </View>
        )}

        {activeTab === "insights" && <InsightsTab onEventPress={(id) => console.log("event", id)} />}
        {activeTab === "guard" && <TriggersTab />}
        {activeTab === "triggers" && <TriggersTab />}
      </SafeAreaView>
    </GestureHandlerRootView>
  );
}
