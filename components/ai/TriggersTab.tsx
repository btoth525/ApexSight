import { useState } from "react";
import {
  View, Text, ScrollView, TouchableOpacity, TextInput,
  Alert, ActivityIndicator, RefreshControl
} from "react-native";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { apiClient } from "@/utils/apiClient";
import { VLMMonitor } from "@/types/api";
import { formatRelativeTime } from "@/utils/timeUtil";
import { Skeleton } from "@/components/ui/Skeleton";

export function TriggersTab() {
  const { data: monitors, isLoading, mutate } = useFrigateApi<VLMMonitor[]>("/vlm/monitors");
  const [creating, setCreating] = useState(false);
  const [newCamera, setNewCamera] = useState("");
  const [newPrompt, setNewPrompt] = useState("");
  const [submitting, setSubmitting] = useState(false);

  const handleCreate = async () => {
    if (!newCamera.trim() || !newPrompt.trim()) {
      Alert.alert("Error", "Camera name and prompt are required.");
      return;
    }
    setSubmitting(true);
    try {
      await apiClient.post("/vlm/monitor", { camera: newCamera, prompt: newPrompt });
      setNewCamera("");
      setNewPrompt("");
      setCreating(false);
      mutate();
    } catch {
      Alert.alert("Error", "Could not create monitor.");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <ScrollView
      className="flex-1"
      contentContainerStyle={{ paddingBottom: 24 }}
      refreshControl={<RefreshControl refreshing={isLoading} onRefresh={() => mutate()} tintColor="#00b4d8" />}
    >
      {/* Create new monitor */}
      <View className="mx-4 mt-4 bg-surface rounded-2xl p-4">
        <View className="flex-row items-center justify-between mb-3">
          <Text className="text-text-primary font-semibold">Watch Triggers</Text>
          <TouchableOpacity
            onPress={() => setCreating(!creating)}
            className="bg-primary rounded-lg px-3 py-1.5"
          >
            <Text className="text-white text-sm font-medium">{creating ? "Cancel" : "+ New"}</Text>
          </TouchableOpacity>
        </View>

        {creating && (
          <View className="gap-3 border-t border-border pt-3">
            <TextInput
              className="bg-surface-2 rounded-xl px-4 py-3 text-text-primary"
              placeholder="Camera name"
              placeholderTextColor="#94a3b8"
              value={newCamera}
              onChangeText={setNewCamera}
              autoCapitalize="none"
            />
            <TextInput
              className="bg-surface-2 rounded-xl px-4 py-3 text-text-primary"
              placeholder="What to watch for (e.g. person near gate)"
              placeholderTextColor="#94a3b8"
              value={newPrompt}
              onChangeText={setNewPrompt}
              multiline
              numberOfLines={3}
            />
            <TouchableOpacity
              onPress={handleCreate}
              disabled={submitting}
              className="bg-primary rounded-xl py-3 items-center"
            >
              {submitting ? <ActivityIndicator color="#fff" size="small" /> : (
                <Text className="text-white font-semibold">Create Monitor</Text>
              )}
            </TouchableOpacity>
          </View>
        )}
      </View>

      {/* Monitor list */}
      {isLoading ? (
        <View className="mx-4 mt-4 gap-3">
          {[1, 2, 3].map(i => <Skeleton key={i} height={80} borderRadius={16} />)}
        </View>
      ) : monitors && monitors.length > 0 ? (
        <View className="mx-4 mt-4 gap-3">
          {monitors.map((monitor) => (
            <View key={monitor.id} className="bg-surface rounded-2xl p-4 border border-border">
              <View className="flex-row items-center justify-between mb-1">
                <Text className="text-text-primary font-semibold">📷 {monitor.camera}</Text>
                <View className={`px-2 py-0.5 rounded-full ${monitor.active ? "bg-success/20" : "bg-surface-2"}`}>
                  <Text className={`text-xs font-medium ${monitor.active ? "text-success" : "text-text-secondary"}`}>
                    {monitor.active ? "Active" : "Inactive"}
                  </Text>
                </View>
              </View>
              <Text className="text-text-secondary text-sm mb-2">{monitor.prompt}</Text>
              {monitor.last_triggered && (
                <Text className="text-text-secondary text-xs">
                  Last: {formatRelativeTime(monitor.last_triggered)}
                </Text>
              )}
            </View>
          ))}
        </View>
      ) : (
        <View className="items-center py-12">
          <Text className="text-3xl mb-3">👁</Text>
          <Text className="text-text-primary">No watch triggers yet</Text>
          <Text className="text-text-secondary text-sm mt-1">Create one to monitor specific activity</Text>
        </View>
      )}
    </ScrollView>
  );
}
