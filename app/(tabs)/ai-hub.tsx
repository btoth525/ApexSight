import { useState } from "react";
import { View, Text, TouchableOpacity } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { GuardStatusCard } from "@/components/ai/GuardStatusCard";
import { InsightsTab } from "@/components/ai/InsightsTab";
import { TriggersTab } from "@/components/ai/TriggersTab";
import { GuardStatus } from "@/types/api";

type Tab = "insights" | "guard";

export default function AIHubScreen() {
  const [activeTab, setActiveTab] = useState<Tab>("insights");
  const { data: guardStatus, mutate: mutateGuard } = useFrigateApi<GuardStatus>("/guard/status");

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaView className="flex-1 bg-background" edges={["top"]}>
        {/* Header */}
        <View className="px-4 py-3 border-b border-surface-2">
          <Text className="text-text-primary text-xl font-bold mb-3">AI Hub</Text>
          <View className="flex-row bg-surface rounded-xl p-1 gap-1">
            {([["insights", "📊 Insights"], ["guard", "🛡️ Guard"]] as const).map(([tab, label]) => (
              <TouchableOpacity
                key={tab}
                onPress={() => setActiveTab(tab)}
                className={`flex-1 py-2 rounded-lg items-center ${activeTab === tab ? "bg-primary" : ""}`}
              >
                <Text className={`text-sm font-medium ${activeTab === tab ? "text-white" : "text-text-secondary"}`}>
                  {label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        {activeTab === "guard" && (
          <View className="mt-4 mb-2">
            <GuardStatusCard status={guardStatus} onToggle={() => mutateGuard()} />
          </View>
        )}

        {activeTab === "insights" ? (
          <InsightsTab onEventPress={(id) => console.log("event", id)} />
        ) : (
          <TriggersTab />
        )}
      </SafeAreaView>
    </GestureHandlerRootView>
  );
}
