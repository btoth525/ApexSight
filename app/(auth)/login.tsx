import { useState } from "react";
import {
  View, Text, TextInput, TouchableOpacity, ActivityIndicator,
  KeyboardAvoidingView, Platform, ScrollView, Image, StatusBar,
} from "react-native";
import { useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import CookieManager from "@react-native-cookies/cookies";
import { useAuthStore } from "@/stores/authStore";
import { apiClient } from "@/utils/apiClient";
import { haptic } from "@/utils/haptics";

export default function LoginScreen() {
  const router = useRouter();
  const { setAuth, setBaseUrl, baseUrl } = useAuthStore();

  const [url, setUrl] = useState(baseUrl || "https://frigate.plexserver525.com");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const doLogin = async (loginUrl: string, loginUser: string, loginPass: string) => {
    const trimmedUrl = loginUrl.replace(/\/$/, "");
    await setBaseUrl(trimmedUrl);
    const res = await apiClient.post("/login", { user: loginUser, password: loginPass });
    if (res.status !== 200) throw new Error("Login failed");
    let token = "session";
    const rawCookie = res.headers?.["set-cookie"];
    if (rawCookie) {
      const cookieStr = Array.isArray(rawCookie) ? rawCookie.join("; ") : rawCookie;
      const match = cookieStr.match(/frigate_token=([^;,\s]+)/);
      if (match?.[1]) token = match[1];
    }
    // URLSession processes Set-Cookie asynchronously — retry up to 5x
    // so we always capture the real JWT rather than falling back to "session"
    if (token === "session") {
      for (let i = 0; i < 5; i++) {
        await new Promise((r) => setTimeout(r, 150));
        const cookies = await CookieManager.get(trimmedUrl);
        const val = cookies["frigate_token"]?.value;
        if (val && val.length > 10) { token = val; break; }
      }
    }
    const name = res.data?.user?.name ?? loginUser;
    await setAuth(token, name);
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
      await doLogin(url, username, password);
      haptic.success();
      router.replace("/browser");
    } catch (e: unknown) {
      haptic.error();
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 401) setError("Invalid username or password.");
      else setError("Could not connect to server. Check the URL.");
    } finally {
      setLoading(false);
    }
  };

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
            <Text style={{ fontSize: 32, fontWeight: "800", color: "#f1f5f9", letterSpacing: -0.5 }}>Apex</Text>
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
                  textContentType="URL"
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
                  textContentType="username"
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
                  textContentType="password"
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
          </View>

          <Text style={{ color: "#475569", fontSize: 11, textAlign: "center", marginTop: 32 }}>
            Connects to your self-hosted Frigate NVR instance
          </Text>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}
