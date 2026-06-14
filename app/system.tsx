import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ActivityIndicator,
  RefreshControl,
  ScrollView,
  Text,
  View,
} from "react-native";
import { useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { AppleMaterial, ApplePressable, apple } from "@/components/AppleMaterial";
import { apiClient } from "@/utils/apiClient";
import { haptic } from "@/utils/haptics";

type Stats = Record<string, unknown>;

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function numeric(value: unknown): number | null {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) ? number : null;
}

function formatNumber(value: unknown, suffix = "") {
  const number = numeric(value);
  if (number === null) return "n/a";
  return `${number.toFixed(number >= 10 ? 0 : 1)}${suffix}`;
}

function linesFromLog(value: unknown) {
  if (Array.isArray(value)) return value.map(String).slice(-12);
  if (typeof value === "string") return value.split(/\r?\n/).filter(Boolean).slice(-12);
  const data = asRecord(value);
  if (Array.isArray(data.lines)) return data.lines.map(String).slice(-12);
  return [];
}

export default function SystemScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const [stats, setStats] = useState<Stats>({});
  const [version, setVersion] = useState("");
  const [logs, setLogs] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setError("");
    try {
      const [statsResult, versionResult, logsResult] = await Promise.allSettled([
        apiClient.get<Stats>("/stats"),
        apiClient.get<unknown>("/version"),
        apiClient.get<unknown>("/logs/frigate"),
      ]);

      if (statsResult.status === "fulfilled") setStats(statsResult.value.data ?? {});
      if (versionResult.status === "fulfilled") {
        const data = versionResult.value.data;
        setVersion(typeof data === "string" ? data : String(asRecord(data).version ?? ""));
      }
      if (logsResult.status === "fulfilled") setLogs(linesFromLog(logsResult.value.data));

      if (statsResult.status === "rejected") throw new Error("Stats unavailable.");
    } catch {
      setError("Could not load Frigate health.");
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const cameras = useMemo(() => asRecord(stats.cameras), [stats]);
  const detectors = useMemo(() => asRecord(stats.detectors), [stats]);
  const service = useMemo(() => asRecord(stats.service), [stats]);
  const cpu = service.cpu_usages ?? stats.cpu_usages;
  const memory = service.mem_usages ?? stats.mem_usages;

  const refresh = useCallback(() => {
    haptic.tap();
    setRefreshing(true);
    load();
  }, [load]);

  return (
    <View style={{ flex: 1, backgroundColor: apple.colors.background }}>
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        refreshControl={<RefreshControl tintColor={apple.colors.cyan} refreshing={refreshing} onRefresh={refresh} />}
        contentContainerStyle={{
          paddingTop: insets.top + 14,
          paddingBottom: insets.bottom + 28,
          paddingHorizontal: 18,
          gap: 16,
        }}
      >
        <View style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
          <ApplePressable
            onPress={() => {
              haptic.tap();
              router.back();
            }}
            accessibilityLabel="Back"
            style={{
              width: 44,
              height: 44,
              borderRadius: 22,
              alignItems: "center",
              justifyContent: "center",
              backgroundColor: "rgba(255,255,255,0.12)",
            }}
          >
            <Ionicons name="chevron-back" size={22} color={apple.colors.label} />
          </ApplePressable>
          <View style={{ flex: 1 }}>
            <Text style={{ color: apple.colors.label, fontSize: 28, fontWeight: "900" }}>System</Text>
            <Text style={{ color: apple.colors.secondaryLabel, fontSize: 13, fontWeight: "700", marginTop: 2 }}>
              {version ? `Frigate ${version}` : "Frigate health"}
            </Text>
          </View>
          {loading ? <ActivityIndicator color={apple.colors.cyan} /> : null}
        </View>

        {error ? (
          <AppleMaterial tint="systemMaterialDark" intensity={88} contentStyle={{ padding: 16 }}>
            <Text style={{ color: apple.colors.orange, fontSize: 14, fontWeight: "800" }}>{error}</Text>
          </AppleMaterial>
        ) : null}

        <AppleMaterial tint="systemChromeMaterialDark" intensity={88} contentStyle={{ padding: 16, gap: 12 }}>
          <Text style={{ color: apple.colors.label, fontSize: 20, fontWeight: "900" }}>Performance</Text>
          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 10 }}>
            <Metric icon="hardware-chip-outline" label="Detectors" value={String(Object.keys(detectors).length || "n/a")} />
            <Metric icon="videocam-outline" label="Cameras" value={String(Object.keys(cameras).length || "n/a")} />
            <Metric icon="speedometer-outline" label="CPU" value={cpu ? "active" : "n/a"} />
            <Metric icon="server-outline" label="Memory" value={memory ? "active" : "n/a"} />
          </View>
        </AppleMaterial>

        {Object.entries(detectors).length ? (
          <AppleMaterial tint="systemMaterialDark" intensity={88} contentStyle={{ padding: 16, gap: 12 }}>
            <Text style={{ color: apple.colors.label, fontSize: 20, fontWeight: "900" }}>Detectors</Text>
            {Object.entries(detectors).map(([name, value]) => {
              const detector = asRecord(value);
              return (
                <InfoRow
                  key={name}
                  icon="flash-outline"
                  title={name}
                  subtitle={`Inference ${formatNumber(detector.inference_speed, "ms")} - PID ${detector.pid ?? "n/a"}`}
                />
              );
            })}
          </AppleMaterial>
        ) : null}

        {Object.entries(cameras).length ? (
          <AppleMaterial tint="systemMaterialDark" intensity={88} contentStyle={{ padding: 16, gap: 12 }}>
            <Text style={{ color: apple.colors.label, fontSize: 20, fontWeight: "900" }}>Cameras</Text>
            {Object.entries(cameras).map(([name, value]) => {
              const camera = asRecord(value);
              return (
                <InfoRow
                  key={name}
                  icon="aperture-outline"
                  title={name.replace(/_/g, " ")}
                  subtitle={`Camera ${formatNumber(camera.camera_fps, " fps")} - Detect ${formatNumber(camera.detection_fps, " fps")} - Process ${formatNumber(camera.process_fps, " fps")}`}
                />
              );
            })}
          </AppleMaterial>
        ) : null}

        <AppleMaterial tint="systemChromeMaterialDark" intensity={88} contentStyle={{ padding: 16, gap: 12 }}>
          <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
            <Text style={{ color: apple.colors.label, fontSize: 20, fontWeight: "900" }}>Recent Logs</Text>
            <ApplePressable
              onPress={refresh}
              accessibilityLabel="Refresh system"
              style={{
                width: 38,
                height: 38,
                borderRadius: 19,
                alignItems: "center",
                justifyContent: "center",
                backgroundColor: "rgba(255,255,255,0.12)",
              }}
            >
              <Ionicons name="refresh" size={17} color={apple.colors.label} />
            </ApplePressable>
          </View>
          {logs.length ? logs.map((line, index) => (
            <Text key={`${index}-${line}`} style={{ color: apple.colors.secondaryLabel, fontSize: 11, lineHeight: 16, fontFamily: "Courier" }}>
              {line}
            </Text>
          )) : (
            <Text style={{ color: apple.colors.secondaryLabel, fontSize: 14, fontWeight: "700" }}>No log lines returned.</Text>
          )}
        </AppleMaterial>
      </ScrollView>
    </View>
  );
}

function Metric({ icon, label, value }: { icon: keyof typeof Ionicons.glyphMap; label: string; value: string }) {
  return (
    <View
      style={{
        minWidth: "47%",
        flexGrow: 1,
        borderRadius: 18,
        padding: 12,
        gap: 8,
        backgroundColor: "rgba(255,255,255,0.07)",
        borderWidth: 1,
        borderColor: "rgba(255,255,255,0.1)",
      }}
    >
      <Ionicons name={icon} size={18} color={apple.colors.green} />
      <Text style={{ color: apple.colors.secondaryLabel, fontSize: 11, fontWeight: "800", textTransform: "uppercase" }}>
        {label}
      </Text>
      <Text style={{ color: apple.colors.label, fontSize: 15, fontWeight: "900" }} numberOfLines={1}>
        {value}
      </Text>
    </View>
  );
}

function InfoRow({ icon, title, subtitle }: { icon: keyof typeof Ionicons.glyphMap; title: string; subtitle: string }) {
  return (
    <View
      style={{
        flexDirection: "row",
        alignItems: "center",
        gap: 12,
        borderRadius: 18,
        padding: 12,
        backgroundColor: "rgba(255,255,255,0.07)",
        borderWidth: 1,
        borderColor: "rgba(255,255,255,0.1)",
      }}
    >
      <View style={{ width: 36, height: 36, borderRadius: 18, alignItems: "center", justifyContent: "center", backgroundColor: "rgba(48,209,88,0.18)" }}>
        <Ionicons name={icon} size={18} color={apple.colors.green} />
      </View>
      <View style={{ flex: 1 }}>
        <Text style={{ color: apple.colors.label, fontSize: 15, fontWeight: "900", textTransform: "capitalize" }} numberOfLines={1}>
          {title}
        </Text>
        <Text style={{ color: apple.colors.secondaryLabel, fontSize: 12, fontWeight: "700", marginTop: 3 }} numberOfLines={2}>
          {subtitle}
        </Text>
      </View>
    </View>
  );
}
