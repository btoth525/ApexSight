import { useState } from "react";
import {
  View, Text, TouchableOpacity, TextInput, Switch,
  ScrollView, Alert, ActivityIndicator, Image
} from "react-native";
import { haptic } from "@/utils/haptics";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRouter } from "expo-router";
import * as Notifications from "expo-notifications";
import { useAuthStore } from "@/stores/authStore";
import { useSettingsStore } from "@/stores/settingsStore";
import { useFrigateApi } from "@/hooks/useFrigateApi";
import { apiClient } from "@/utils/apiClient";
import { useBiometrics } from "@/hooks/useBiometrics";

type Section = { title: string; children: React.ReactNode };

function SettingsSection({ title, children }: Section) {
  return (
    <View className="mx-4 mb-4">
      <Text className="text-text-secondary text-xs font-semibold uppercase tracking-wide mb-2 ml-1">
        {title}
      </Text>
      <View className="bg-surface rounded-2xl overflow-hidden border border-border">
        {children}
      </View>
    </View>
  );
}

function SettingsRow({ label, children, onPress, last }: {
  label: string; children?: React.ReactNode; onPress?: () => void; last?: boolean;
}) {
  const Row = onPress ? TouchableOpacity : View;
  return (
    <Row
      onPress={onPress}
      className={`flex-row items-center justify-between px-4 py-3.5 ${!last ? "border-b border-surface-2" : ""}`}
      activeOpacity={0.7}
    >
      <Text className="text-text-primary">{label}</Text>
      {children}
    </Row>
  );
}

export default function SettingsScreen() {
  const router = useRouter();
  const { logout, username, baseUrl, setBaseUrl } = useAuthStore();
  const { notificationsEnabled, setNotificationsEnabled } = useSettingsStore();
  const { biometricType, isAvailable: biometricsAvailable } = useBiometrics();
  const { data: versionData } = useFrigateApi<{ version: string }>("/version");

  const [editingUrl, setEditingUrl] = useState(false);
  const [urlDraft, setUrlDraft] = useState(baseUrl);
  const [registeringPasskey, setRegisteringPasskey] = useState(false);

  const handleSaveUrl = () => {
    const trimmed = urlDraft.replace(/\/$/, "");
    setBaseUrl(trimmed);
    setEditingUrl(false);
  };

  const handleLogout = () => {
    Alert.alert("Sign Out", "Are you sure you want to sign out?", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Sign Out", style: "destructive",
        onPress: () => { logout(); router.replace("/(auth)/login"); }
      },
    ]);
  };

  const handleToggleNotifications = async (value: boolean) => {
    if (value) {
      const { status } = await Notifications.requestPermissionsAsync();
      if (status !== "granted") {
        haptic.error();
        Alert.alert("Permission Required", "Enable notifications in iOS Settings.");
        return;
      }
    }
    haptic.medium();
    setNotificationsEnabled(value);
  };

  const handleRegisterPasskey = async () => {
    setRegisteringPasskey(true);
    try {
      await apiClient.post("/auth/webauthn/register/begin", {});
      Alert.alert("Success", `${biometricType ?? "Biometric"} registered for login.`);
    } catch {
      Alert.alert("Error", "Could not register passkey. Try again.");
    } finally {
      setRegisteringPasskey(false);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-background" edges={["top"]}>
      <ScrollView contentContainerStyle={{ paddingBottom: 40 }}>
        <View className="px-4 py-4 border-b border-surface-2 mb-4 flex-row items-center gap-3">
          <Image
            source={require("@/assets/icon.png")}
            style={{ width: 40, height: 40, borderRadius: 9 }}
            resizeMode="cover"
          />
          <Text className="text-text-primary text-xl font-bold">Settings</Text>
        </View>

        {/* Account */}
        <SettingsSection title="Account">
          <SettingsRow label="Signed in as" last>
            <Text className="text-text-secondary">{username ?? "—"}</Text>
          </SettingsRow>
        </SettingsSection>

        {/* Server */}
        <SettingsSection title="Server">
          {editingUrl ? (
            <View className="px-4 py-3">
              <TextInput
                className="bg-surface-2 rounded-xl px-3 py-2.5 text-text-primary mb-3"
                value={urlDraft}
                onChangeText={setUrlDraft}
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="url"
              />
              <View className="flex-row gap-3">
                <TouchableOpacity
                  onPress={() => { setUrlDraft(baseUrl); setEditingUrl(false); }}
                  className="flex-1 bg-surface-2 rounded-xl py-2.5 items-center"
                >
                  <Text className="text-text-secondary">Cancel</Text>
                </TouchableOpacity>
                <TouchableOpacity
                  onPress={handleSaveUrl}
                  className="flex-1 bg-primary rounded-xl py-2.5 items-center"
                >
                  <Text className="text-white font-semibold">Save</Text>
                </TouchableOpacity>
              </View>
            </View>
          ) : (
            <SettingsRow label="Server URL" onPress={() => setEditingUrl(true)} last>
              <Text className="text-text-secondary text-sm" numberOfLines={1} style={{ maxWidth: 180 }}>
                {baseUrl || "Not set"}
              </Text>
            </SettingsRow>
          )}
        </SettingsSection>

        {/* Security */}
        {biometricsAvailable && (
          <SettingsSection title="Security">
            <SettingsRow
              label={`Register ${biometricType ?? "Biometric"}`}
              onPress={handleRegisterPasskey}
              last
            >
              {registeringPasskey ? (
                <ActivityIndicator color="#00b4d8" size="small" />
              ) : (
                <Text className="text-primary text-sm">Set up →</Text>
              )}
            </SettingsRow>
          </SettingsSection>
        )}

        {/* Notifications */}
        <SettingsSection title="Notifications">
          <SettingsRow label="Enable Notifications" last>
            <Switch
              value={notificationsEnabled}
              onValueChange={handleToggleNotifications}
              trackColor={{ false: "#334155", true: "#00b4d8" }}
              thumbColor="#fff"
            />
          </SettingsRow>
        </SettingsSection>

        {/* Camera Tour */}
        <SettingsSection title="Features">
          <SettingsRow label="Camera Tour" onPress={() => router.push("/camera-tour")} last>
            <Text className="text-primary text-sm">Open →</Text>
          </SettingsRow>
        </SettingsSection>

        {/* About */}
        <SettingsSection title="About">
          <SettingsRow label="App Version">
            <Text className="text-text-secondary text-sm">1.0.0</Text>
          </SettingsRow>
          <SettingsRow label="Frigate Version" last>
            <Text className="text-text-secondary text-sm">{versionData?.version ?? "—"}</Text>
          </SettingsRow>
        </SettingsSection>

        {/* Sign out */}
        <View className="mx-4 mt-2">
          <TouchableOpacity
            onPress={handleLogout}
            className="bg-danger/20 border border-danger/40 rounded-2xl py-4 items-center"
          >
            <Text className="text-danger font-semibold">Sign Out</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}
