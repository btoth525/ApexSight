import { useState } from "react";
import {
  View, Text, TouchableOpacity, TextInput, Switch,
  ScrollView, Alert, ActivityIndicator, Image, StatusBar,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import * as Notifications from "expo-notifications";
import CookieManager from "@react-native-cookies/cookies";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { useBiometrics } from "@/hooks/useBiometrics";
import { haptic } from "@/utils/haptics";

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <View style={{ marginHorizontal: 16, marginBottom: 18 }}>
      <Text style={{ color: "#475569", fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 1, marginBottom: 8, marginLeft: 4 }}>
        {title}
      </Text>
      <View style={{ backgroundColor: "#1e293b", borderRadius: 14, overflow: "hidden", borderWidth: 1, borderColor: "#1e293b" }}>
        {children}
      </View>
    </View>
  );
}

function Row({
  icon, iconColor = "#00d4ff", label, sublabel, children, onPress, last, danger,
}: {
  icon?: React.ComponentProps<typeof Ionicons>["name"];
  iconColor?: string;
  label: string;
  sublabel?: string;
  children?: React.ReactNode;
  onPress?: () => void;
  last?: boolean;
  danger?: boolean;
}) {
  const Comp: any = onPress ? TouchableOpacity : View;
  return (
    <Comp
      onPress={onPress ? () => { haptic.tap(); onPress(); } : undefined}
      activeOpacity={0.7}
      style={{
        flexDirection: "row", alignItems: "center",
        paddingHorizontal: 14, paddingVertical: 13,
        borderBottomWidth: last ? 0 : 1, borderBottomColor: "#0a0f1e",
        gap: 12,
      }}
    >
      {icon && (
        <View style={{ width: 32, height: 32, borderRadius: 8, backgroundColor: danger ? "#ef444422" : `${iconColor}22`, alignItems: "center", justifyContent: "center" }}>
          <Ionicons name={icon} size={17} color={danger ? "#ef4444" : iconColor} />
        </View>
      )}
      <View style={{ flex: 1 }}>
        <Text style={{ color: danger ? "#ef4444" : "#f1f5f9", fontSize: 15, fontWeight: "500" }}>{label}</Text>
        {sublabel && <Text style={{ color: "#64748b", fontSize: 12, marginTop: 2 }}>{sublabel}</Text>}
      </View>
      {children}
      {onPress && !children && <Ionicons name="chevron-forward" size={16} color="#475569" />}
    </Comp>
  );
}

export default function SettingsScreen() {
  const router = useRouter();
  const { logout, username, baseUrl, setBaseUrl, token } = useAuthStore();
  const { notificationsEnabled, setNotificationsEnabled } = useSettingsStore();
  const { biometricType, isAvailable: biometricsAvailable, hasStoredCredentials, clearCredentials } = useBiometrics();
  const { data: versionData } = useFrigateApi<{ version: string }>("/version");
  const { data: config } = useFrigateApi<{ cameras: Record<string, any> }>("/config");

  const [editingUrl, setEditingUrl] = useState(false);
  const [urlDraft, setUrlDraft] = useState(baseUrl);

  const cameraCount = config?.cameras ? Object.keys(config.cameras).length : 0;

  const handleSaveUrl = () => {
    const trimmed = urlDraft.replace(/\/$/, "");
    setBaseUrl(trimmed);
    setEditingUrl(false);
    haptic.success();
  };

  const handleLogout = () => {
    Alert.alert("Sign Out", "Are you sure you want to sign out?", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Sign Out", style: "destructive",
        onPress: async () => {
          haptic.medium();
          if (baseUrl) await CookieManager.clearAll();
          await clearCredentials();
          logout();
          router.replace("/(auth)/login");
        }
      },
    ]);
  };

  const handleDisableBiometric = () => {
    Alert.alert(
      `Disable ${biometricType ?? "Biometric"} Login`,
      "You'll need to enter your password to sign in next time.",
      [
        { text: "Cancel", style: "cancel" },
        { text: "Disable", style: "destructive", onPress: async () => {
            await clearCredentials();
            haptic.warning();
          }
        },
      ]
    );
  };

  const handleToggleNotifications = async (value: boolean) => {
    if (value) {
      const { status } = await Notifications.requestPermissionsAsync();
      if (status !== "granted") {
        haptic.error();
        Alert.alert("Permission Required", "Enable notifications in iOS Settings → Apex Sight.");
        return;
      }
    }
    haptic.medium();
    setNotificationsEnabled(value);
  };

  const sendTestNotification = async () => {
    haptic.tap();
    await Notifications.scheduleNotificationAsync({
      content: {
        title: "🔔 Apex Sight Test",
        body: "Notifications are working. Alerts from Frigate will appear here.",
        sound: "default",
      },
      trigger: null,
    });
  };

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: "#0a0f1e" }} edges={["top"]}>
      <StatusBar barStyle="light-content" />
      <ScrollView contentContainerStyle={{ paddingBottom: 40 }}>

        {/* Header */}
        <View style={{ paddingHorizontal: 16, paddingVertical: 14, borderBottomWidth: 1, borderBottomColor: "#1e293b", flexDirection: "row", alignItems: "center", gap: 12, marginBottom: 16 }}>
          <Image
            source={require("@/assets/icon.png")}
            style={{ width: 42, height: 42, borderRadius: 10 }}
            resizeMode="cover"
          />
          <View style={{ flex: 1 }}>
            <Text style={{ color: "#f1f5f9", fontSize: 20, fontWeight: "700" }}>Settings</Text>
            <Text style={{ color: "#64748b", fontSize: 12 }}>Apex Sight · v1.0.0</Text>
          </View>
        </View>

        <Section title="Account">
          <Row icon="person-circle" label="Signed in" sublabel={username ?? "—"} last />
        </Section>

        <Section title="Server">
          {editingUrl ? (
            <View style={{ padding: 14 }}>
              <TextInput
                style={{ backgroundColor: "#0a0f1e", borderRadius: 10, paddingHorizontal: 12, paddingVertical: 10, color: "#f1f5f9", marginBottom: 12 }}
                value={urlDraft}
                onChangeText={setUrlDraft}
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="url"
              />
              <View style={{ flexDirection: "row", gap: 10 }}>
                <TouchableOpacity onPress={() => { setUrlDraft(baseUrl); setEditingUrl(false); }} style={{ flex: 1, backgroundColor: "#0a0f1e", borderRadius: 10, paddingVertical: 10, alignItems: "center" }}>
                  <Text style={{ color: "#94a3b8" }}>Cancel</Text>
                </TouchableOpacity>
                <TouchableOpacity onPress={handleSaveUrl} style={{ flex: 1, backgroundColor: "#00d4ff", borderRadius: 10, paddingVertical: 10, alignItems: "center" }}>
                  <Text style={{ color: "#0a0f1e", fontWeight: "700" }}>Save</Text>
                </TouchableOpacity>
              </View>
            </View>
          ) : (
            <Row icon="server" label="Server URL" sublabel={baseUrl} onPress={() => setEditingUrl(true)} last />
          )}
        </Section>

        {biometricsAvailable && (
          <Section title="Security">
            {hasStoredCredentials ? (
              <Row
                icon={biometricType === "Face ID" ? "scan-circle" : "finger-print"}
                label={`${biometricType} Login`}
                sublabel="Enabled — tap to disable"
                onPress={handleDisableBiometric}
                last
              >
                <View style={{ backgroundColor: "#00d4ff22", borderRadius: 99, paddingHorizontal: 8, paddingVertical: 3 }}>
                  <Text style={{ color: "#00d4ff", fontSize: 11, fontWeight: "700" }}>ON</Text>
                </View>
              </Row>
            ) : (
              <Row
                icon={biometricType === "Face ID" ? "scan-circle" : "finger-print"}
                label={`Enable ${biometricType} Login`}
                sublabel="Sign in once with password to set up"
                last
              >
                <Text style={{ color: "#64748b", fontSize: 12 }}>Off</Text>
              </Row>
            )}
          </Section>
        )}

        <Section title="Notifications">
          <Row icon="notifications" label="Push Alerts" sublabel="Get notified on motion alerts">
            <Switch
              value={notificationsEnabled}
              onValueChange={handleToggleNotifications}
              trackColor={{ false: "#334155", true: "#00d4ff" }}
              thumbColor="#fff"
              ios_backgroundColor="#334155"
            />
          </Row>
          <Row
            icon="paper-plane"
            iconColor="#a855f7"
            label="Send Test Notification"
            sublabel="Verify alerts are working"
            onPress={sendTestNotification}
            last
          />
        </Section>

        <Section title="Features">
          <Row icon="play-circle" iconColor="#22c55e" label="Camera Tour" sublabel={`${cameraCount} cameras · landscape slideshow`} onPress={() => router.push("/camera-tour")} last />
        </Section>

        <Section title="About">
          <Row icon="phone-portrait" label="App Version">
            <Text style={{ color: "#64748b", fontSize: 13 }}>1.0.0</Text>
          </Row>
          <Row icon="hardware-chip" label="Frigate Version" last>
            <Text style={{ color: "#64748b", fontSize: 13 }}>{versionData?.version ?? "—"}</Text>
          </Row>
        </Section>

        <Section title="Danger Zone">
          <Row icon="log-out" label="Sign Out" onPress={handleLogout} danger last />
        </Section>
      </ScrollView>
    </SafeAreaView>
  );
}
