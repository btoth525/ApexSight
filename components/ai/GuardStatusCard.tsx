import { View, Text, TouchableOpacity, ActivityIndicator } from "react-native";
import { useState } from "react";
import { apiClient } from "@/utils/apiClient";
import { GuardStatus } from "@/types/api";
import { formatRelativeTime } from "@/utils/timeUtil";

type GuardStatusCardProps = {
  status: GuardStatus | undefined;
  onToggle: () => void;
};

export function GuardStatusCard({ status, onToggle }: GuardStatusCardProps) {
  const [toggling, setToggling] = useState(false);

  const handleToggle = async () => {
    setToggling(true);
    try {
      if (status?.active) {
        await apiClient.post("/guard/stop");
      } else {
        await apiClient.post("/guard/start");
      }
      onToggle();
    } catch {}
    finally { setToggling(false); }
  };

  return (
    <View className={`mx-4 rounded-2xl p-4 border ${status?.active ? "bg-primary/10 border-primary/40" : "bg-surface border-border"}`}>
      <View className="flex-row items-center justify-between">
        <View>
          <View className="flex-row items-center gap-2 mb-1">
            <Text className="text-xl">🛡️</Text>
            <Text className="text-text-primary font-bold text-lg">Guard Mode</Text>
          </View>
          <Text className={`text-sm ${status?.active ? "text-primary" : "text-text-secondary"}`}>
            {status?.active ? "Active" : "Inactive"}
          </Text>
          {status?.active && status.start_time && (
            <Text className="text-text-secondary text-xs mt-0.5">
              Started {formatRelativeTime(status.start_time)}
            </Text>
          )}
        </View>
        <TouchableOpacity
          onPress={handleToggle}
          disabled={toggling}
          className={`px-5 py-2.5 rounded-xl ${status?.active ? "bg-danger" : "bg-primary"}`}
        >
          {toggling ? (
            <ActivityIndicator color="#fff" size="small" />
          ) : (
            <Text className="text-white font-semibold">
              {status?.active ? "Stop" : "Start"}
            </Text>
          )}
        </TouchableOpacity>
      </View>
    </View>
  );
}
