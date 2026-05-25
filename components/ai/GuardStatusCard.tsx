import { View, Text, TouchableOpacity, ActivityIndicator } from "react-native";
import { useState } from "react";
import { Ionicons } from "@expo/vector-icons";
import { apiClient } from "@/utils/apiClient";
import { GuardStatus } from "@/types/api";
import { formatRelativeTime } from "@/utils/timeUtil";
import { haptic } from "@/utils/haptics";

type Props = { status: GuardStatus | undefined; onToggle: () => void };

export function GuardStatusCard({ status, onToggle }: Props) {
  const [toggling, setToggling] = useState(false);
  const active = !!status?.active;

  const handleToggle = async () => {
    haptic.heavy();
    setToggling(true);
    try {
      if (active) await apiClient.post("/guard/stop");
      else        await apiClient.post("/guard/start");
      haptic.success();
      onToggle();
    } catch {
      haptic.error();
    } finally { setToggling(false); }
  };

  return (
    <View
      style={{
        marginHorizontal: 16, borderRadius: 16, padding: 16,
        backgroundColor: active ? "#00d4ff14" : "#1e293b",
        borderWidth: 1, borderColor: active ? "#00d4ff66" : "#1e293b",
      }}
    >
      <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between" }}>
        <View style={{ flex: 1 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 8, marginBottom: 4 }}>
            <View style={{ width: 32, height: 32, borderRadius: 9, backgroundColor: active ? "#00d4ff33" : "#0a0f1e", alignItems: "center", justifyContent: "center" }}>
              <Ionicons name="shield-checkmark" size={18} color={active ? "#00d4ff" : "#64748b"} />
            </View>
            <Text style={{ color: "#f1f5f9", fontWeight: "700", fontSize: 17 }}>Guard Mode</Text>
          </View>
          <Text style={{ color: active ? "#00d4ff" : "#94a3b8", fontSize: 13, fontWeight: "600", marginLeft: 40 }}>
            {active ? "● Active — monitoring" : "○ Inactive"}
          </Text>
          {active && status?.start_time && (
            <Text style={{ color: "#64748b", fontSize: 11, marginTop: 2, marginLeft: 40 }}>
              Started {formatRelativeTime(status.start_time)}
            </Text>
          )}
        </View>
        <TouchableOpacity
          onPress={handleToggle}
          disabled={toggling}
          style={{
            paddingHorizontal: 18, paddingVertical: 10, borderRadius: 10,
            backgroundColor: active ? "#ef4444" : "#00d4ff",
            shadowColor: active ? "#ef4444" : "#00d4ff", shadowOpacity: 0.25, shadowRadius: 8,
          }}
        >
          {toggling ? <ActivityIndicator color="#fff" size="small" /> : (
            <Text style={{ color: active ? "#fff" : "#0a0f1e", fontWeight: "700", fontSize: 14 }}>
              {active ? "STOP" : "START"}
            </Text>
          )}
        </TouchableOpacity>
      </View>
    </View>
  );
}
