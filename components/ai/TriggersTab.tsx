import { useState } from "react";
import {
  View, Text, ScrollView, TouchableOpacity, TextInput,
  Alert, ActivityIndicator, RefreshControl,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { apiClient } from "@/utils/apiClient";
import { VLMMonitor, VLMMonitorsResponse } from "@/types/api";
import { formatRelativeTime } from "@/utils/timeUtil";
import { Skeleton } from "@/components/ui/Skeleton";
import { haptic } from "@/utils/haptics";

export function TriggersTab() {
  const { data: monitorsResponse, isLoading, mutate } = useFrigateApi<VLMMonitorsResponse>("/vlm/monitors");
  const monitors = monitorsResponse?.watches;
  const [creating, setCreating] = useState(false);
  const [newCamera, setNewCamera] = useState("");
  const [newPrompt, setNewPrompt] = useState("");
  const [submitting, setSubmitting] = useState(false);

  const handleCreate = async () => {
    if (!newCamera.trim() || !newPrompt.trim()) {
      haptic.warning();
      Alert.alert("Required", "Camera name and prompt are required.");
      return;
    }
    haptic.medium();
    setSubmitting(true);
    try {
      await apiClient.post("/vlm/monitor", { camera: newCamera, condition: newPrompt });
      setNewCamera(""); setNewPrompt(""); setCreating(false);
      haptic.success();
      mutate();
    } catch {
      haptic.error();
      Alert.alert("Error", "Could not create monitor. VLM may not be configured.");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <ScrollView
      contentContainerStyle={{ paddingBottom: 24 }}
      refreshControl={<RefreshControl refreshing={isLoading} onRefresh={() => mutate()} tintColor="#00d4ff" />}
    >
      {/* Create card */}
      <View style={{ marginHorizontal: 16, marginTop: 16, backgroundColor: "#1e293b", borderRadius: 14, padding: 14 }}>
        <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: creating ? 12 : 0 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
            <Ionicons name="flash" size={18} color="#a855f7" />
            <Text style={{ color: "#f1f5f9", fontWeight: "700", fontSize: 15 }}>Watch Triggers</Text>
          </View>
          <TouchableOpacity
            onPress={() => { haptic.tap(); setCreating(!creating); }}
            style={{ backgroundColor: creating ? "#0a0f1e" : "#a855f7", borderRadius: 8, paddingHorizontal: 12, paddingVertical: 6, flexDirection: "row", alignItems: "center", gap: 4 }}
          >
            <Ionicons name={creating ? "close" : "add"} size={14} color={creating ? "#94a3b8" : "#fff"} />
            <Text style={{ color: creating ? "#94a3b8" : "#fff", fontWeight: "700", fontSize: 13 }}>{creating ? "Cancel" : "New"}</Text>
          </TouchableOpacity>
        </View>

        {creating && (
          <View style={{ gap: 10, borderTopWidth: 1, borderTopColor: "#0a0f1e", paddingTop: 12 }}>
            <View style={{ flexDirection: "row", alignItems: "center", gap: 8, backgroundColor: "#0a0f1e", borderRadius: 10, paddingHorizontal: 12 }}>
              <Ionicons name="videocam-outline" size={16} color="#475569" />
              <TextInput
                style={{ flex: 1, paddingVertical: 11, color: "#f1f5f9", fontSize: 14 }}
                placeholder="Camera name (e.g. driveway)"
                placeholderTextColor="#475569"
                value={newCamera}
                onChangeText={setNewCamera}
                autoCapitalize="none"
              />
            </View>
            <View style={{ flexDirection: "row", alignItems: "flex-start", gap: 8, backgroundColor: "#0a0f1e", borderRadius: 10, paddingHorizontal: 12, paddingTop: 4 }}>
              <Ionicons name="eye-outline" size={16} color="#475569" style={{ marginTop: 10 }} />
              <TextInput
                style={{ flex: 1, paddingVertical: 10, color: "#f1f5f9", fontSize: 14, minHeight: 60 }}
                placeholder="Condition to watch for (e.g. person carrying a package)"
                placeholderTextColor="#475569"
                value={newPrompt}
                onChangeText={setNewPrompt}
                multiline
              />
            </View>
            <TouchableOpacity
              onPress={handleCreate}
              disabled={submitting}
              style={{ backgroundColor: "#a855f7", borderRadius: 10, paddingVertical: 12, alignItems: "center" }}
            >
              {submitting ? <ActivityIndicator color="#fff" size="small" /> : (
                <Text style={{ color: "#fff", fontWeight: "700" }}>Create Monitor</Text>
              )}
            </TouchableOpacity>
          </View>
        )}
      </View>

      {/* Monitor list */}
      {isLoading ? (
        <View style={{ marginHorizontal: 16, marginTop: 12, gap: 10 }}>
          {[1, 2, 3].map(i => <Skeleton key={i} height={80} borderRadius={14} />)}
        </View>
      ) : monitors && monitors.length > 0 ? (
        <View style={{ marginHorizontal: 16, marginTop: 12, gap: 10 }}>
          {monitors.map((monitor) => {
            const isActive = monitor.status === "active" || monitor.status === "running";
            return (
              <View key={monitor.id} style={{ backgroundColor: "#1e293b", borderRadius: 14, padding: 14, borderWidth: 1, borderColor: isActive ? "#22c55e44" : "#1e293b" }}>
                <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: 6 }}>
                  <View style={{ flexDirection: "row", alignItems: "center", gap: 6 }}>
                    <Ionicons name="videocam" size={14} color="#94a3b8" />
                    <Text style={{ color: "#f1f5f9", fontWeight: "700", textTransform: "capitalize" }}>
                      {(monitor.camera_friendly || monitor.camera).replace(/_/g, " ")}
                    </Text>
                  </View>
                  <View style={{ flexDirection: "row", alignItems: "center", gap: 4, backgroundColor: isActive ? "#22c55e22" : "#0a0f1e", borderRadius: 99, paddingHorizontal: 8, paddingVertical: 2 }}>
                    <View style={{ width: 5, height: 5, borderRadius: 3, backgroundColor: isActive ? "#22c55e" : "#475569" }} />
                    <Text style={{ color: isActive ? "#22c55e" : "#64748b", fontSize: 11, fontWeight: "700" }}>
                      {isActive ? "ACTIVE" : monitor.status?.toUpperCase() ?? "INACTIVE"}
                    </Text>
                  </View>
                </View>
                <Text style={{ color: "#94a3b8", fontSize: 13, marginBottom: 6 }}>{monitor.condition}</Text>
                {monitor.iteration_count > 0 && (
                  <Text style={{ color: "#64748b", fontSize: 11 }}>
                    {monitor.iteration_count} check{monitor.iteration_count !== 1 ? "s" : ""} run
                    {monitor.auto_renew ? " · auto-renews" : ""}
                  </Text>
                )}
              </View>
            );
          })}
        </View>
      ) : (
        <View style={{ alignItems: "center", paddingTop: 60, paddingHorizontal: 32 }}>
          <Ionicons name="eye-off-outline" size={48} color="#334155" />
          <Text style={{ color: "#f1f5f9", fontSize: 15, fontWeight: "600", marginTop: 14 }}>No triggers yet</Text>
          <Text style={{ color: "#64748b", fontSize: 12, marginTop: 4, textAlign: "center" }}>
            Create a VLM monitor to watch for specific activity
          </Text>
        </View>
      )}
    </ScrollView>
  );
}
