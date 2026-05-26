import { useState, useEffect } from "react";
import {
  View, Text, TextInput, TouchableOpacity, ActivityIndicator,
  KeyboardAvoidingView, Platform, ScrollView, Alert, Image, StatusBar,
} from "react-native";
import { useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import CookieManager from "@react-native-cookies/cookies";
import { useAuthStore } from "@/stores/authStore";
import { apiClient } from "@/utils/apiClient";
import { useBiometrics } from "@/hooks/useBiometrics";
import { haptic } from "@/utils/haptics";

export default function LoginScreen() {
  const router = useRouter();
  const { setAuth, setBaseUrl, baseUrl } = useAuthStore();
  const {
    isAvailable: biometricsAvailable,
    biometricType,
    hasStoredCredentials,
    saveCredentials,
    getCredentials,
  } = useBiometrics();

  const [url, setUrl] = useState(baseUrl || "https://frigate.plexserver525.com");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const doLogin = async (loginUrl: string, loginUser: string, loginPass: string) => {
    const trimmedUrl = loginUrl.replace(/\/$/, "");
    setBaseUrl(trimmedUrl);
    const res = await apiClient.post("/login", { user: loginUser, password: loginPass });
    if (res.status !== 200) throw new Error("Login failed");
    const cookies = await CookieManager.get(trimmedUrl);
    const token = cookies["frigate_token"]?.value ?? "session";
    const name = res.data?.user?.name ?? loginUser;
    setAuth(token, name);
    return { trimmedUrl, name };
  };

  const handleLogin = async () => {
    if (!url.trim() || !username.trim() || !password.trim()) {
      setError("Please fill in all fields.");
      return;
    }
    setLoading(true);
    setError("");
    try {
      const { trimmedUrl } = await doLogin(url, username, password);
      haptic.success();
      // Offer to enable biometric login after successful sign-in
      if (biometricsAvailable && !hasStoredCredentials) {
        Alert.alert(
          `Enable ${biometricType ?? "Biometric"} Login?`,
          `Sign in next time with ${biometricType ?? "your biometric"} instead of typing your password.`,
          [
            { text: "Not Now", style: "cancel", onPress: () => router.replace("/browser") },
            {
              text: "Enable",
              onPress: async () => {
                try {
                  await saveCredentials(trimmedUrl, username, password);
                  haptic.success();
                } catch {
                  // user cancelled biometric prompt — that's fine
                }
                router.replace("/browser");
              },
            },
          ]
        );
      } else {
        router.replace("/browser");
      }
    } catch (e: unknown) {
      haptic.error();
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 401) setError("Invalid username or password.");
      else setError("Could not connect to server. Check the URL.");
    } finally {
      setLoading(false);
    }
  };

  const handleBiometricLogin = async () => {
    if (!hasStoredCredentials) {
      setError(`Sign in with password first, then enable ${biometricType ?? "biometric"} login.`);
      return;
    }
    setLoading(true);
    setError("");
    try {
      const creds = await getCredentials();
      if (!creds) {
        haptic.warning();
        setError(`${biometricType ?? "Biometric"} cancelled.`);
        setLoading(false);
        return;
      }
      await doLogin(creds.url, creds.username, creds.password);
      haptic.success();
      router.replace("/browser");
    } catch {
      haptic.error();
      setError(`${biometricType ?? "Biometric"} login failed. Try password.`);
    } finally {
      setLoading(false);
    }
  };

  // Auto-prompt for Face ID if credentials are stored
  useEffect(() => {
    if (biometricsAvailable && hasStoredCredentials && !loading) {
      const t = setTimeout(() => { handleBiometricLogin(); }, 350);
      return () => clearTimeout(t);
    }
  }, [biometricsAvailable, hasStoredCredentials]);

  const bioIcon = biometricType === "Face ID" ? "scan-circle" : "finger-print";

  return (
    <KeyboardAvoidingView
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      style={{ flex: 1, backgroundColor: "#0a0f1e" }}
    >
      <StatusBar barStyle="light-content" />
      <ScrollView contentContainerStyle={{ flexGrow: 1 }} keyboardShouldPersistTaps="handled">
        <View style={{ flex: 1, justifyContent: "center", paddingHorizontal: 24, paddingVertical: 48 }}>

          {/* Logo header */}
          <View style={{ alignItems: "center", marginBottom: 40 }}>
            <Image
              source={require("@/assets/icon.png")}
              style={{ width: 120, height: 120, borderRadius: 28, marginBottom: 20 }}
              resizeMode="cover"
            />
            <Text style={{ fontSize: 32, fontWeight: "800", color: "#f1f5f9", letterSpacing: -0.5 }}>Apex Sight</Text>
            <Text style={{ color: "#64748b", marginTop: 4, fontSize: 14 }}>Frigate NVR · Native iOS</Text>
          </View>

          {/* Form */}
          <View style={{ gap: 14 }}>
            <View>
              <Text style={{ color: "#64748b", fontSize: 12, fontWeight: "600", marginBottom: 6, marginLeft: 4, textTransform: "uppercase", letterSpacing: 0.5 }}>Server URL</Text>
              <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#1e293b", borderRadius: 12, paddingHorizontal: 14, gap: 10, borderWidth: 1, borderColor: "#334155" }}>
                <Ionicons name="globe-outline" size={18} color="#475569" />
                <TextInput
                  style={{ flex: 1, paddingVertical: 14, color: "#f1f5f9", fontSize: 15 }}
                  placeholder="https://your-frigate-host.com"
                  placeholderTextColor="#475569"
                  value={url}
                  onChangeText={setUrl}
                  autoCapitalize="none"
                  autoCorrect={false}
                  keyboardType="url"
                />
              </View>
            </View>

            <View>
              <Text style={{ color: "#64748b", fontSize: 12, fontWeight: "600", marginBottom: 6, marginLeft: 4, textTransform: "uppercase", letterSpacing: 0.5 }}>Username</Text>
              <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#1e293b", borderRadius: 12, paddingHorizontal: 14, gap: 10, borderWidth: 1, borderColor: "#334155" }}>
                <Ionicons name="person-outline" size={18} color="#475569" />
                <TextInput
                  style={{ flex: 1, paddingVertical: 14, color: "#f1f5f9", fontSize: 15 }}
                  placeholder="admin"
                  placeholderTextColor="#475569"
                  value={username}
                  onChangeText={setUsername}
                  autoCapitalize="none"
                  autoCorrect={false}
                />
              </View>
            </View>

            <View>
              <Text style={{ color: "#64748b", fontSize: 12, fontWeight: "600", marginBottom: 6, marginLeft: 4, textTransform: "uppercase", letterSpacing: 0.5 }}>Password</Text>
              <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: "#1e293b", borderRadius: 12, paddingHorizontal: 14, gap: 10, borderWidth: 1, borderColor: "#334155" }}>
                <Ionicons name="lock-closed-outline" size={18} color="#475569" />
                <TextInput
                  style={{ flex: 1, paddingVertical: 14, color: "#f1f5f9", fontSize: 15 }}
                  placeholder="••••••••"
                  placeholderTextColor="#475569"
                  value={password}
                  onChangeText={setPassword}
                  secureTextEntry
                />
              </View>
            </View>

            {error ? (
              <View style={{ flexDirection: "row", alignItems: "center", gap: 6, justifyContent: "center", marginTop: 4 }}>
                <Ionicons name="warning" size={14} color="#ef4444" />
                <Text style={{ color: "#ef4444", fontSize: 13 }}>{error}</Text>
              </View>
            ) : null}

            <TouchableOpacity
              style={{ backgroundColor: "#00d4ff", borderRadius: 12, paddingVertical: 16, alignItems: "center", marginTop: 8, shadowColor: "#00d4ff", shadowOpacity: 0.3, shadowRadius: 12, shadowOffset: { width: 0, height: 0 } }}
              onPress={handleLogin}
              disabled={loading}
            >
              {loading ? (
                <ActivityIndicator color="#0a0f1e" />
              ) : (
                <Text style={{ color: "#0a0f1e", fontWeight: "700", fontSize: 16, letterSpacing: 0.3 }}>Sign In</Text>
              )}
            </TouchableOpacity>

            {biometricsAvailable && (
              <TouchableOpacity
                style={{ flexDirection: "row", justifyContent: "center", alignItems: "center", gap: 8, backgroundColor: "#1e293b", borderWidth: 1, borderColor: "#334155", borderRadius: 12, paddingVertical: 14, marginTop: 2 }}
                onPress={handleBiometricLogin}
                disabled={loading}
              >
                <Ionicons name={bioIcon as any} size={20} color="#00d4ff" />
                <Text style={{ color: "#f1f5f9", fontWeight: "600", fontSize: 15 }}>
                  {hasStoredCredentials ? `Sign in with ${biometricType}` : `${biometricType} (sign in first)`}
                </Text>
              </TouchableOpacity>
            )}
          </View>

          <Text style={{ color: "#475569", fontSize: 11, textAlign: "center", marginTop: 32 }}>
            Connects to your self-hosted Frigate NVR instance
          </Text>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}
