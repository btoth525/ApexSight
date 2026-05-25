import { useState, useEffect } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  Alert,
} from "react-native";
import { useRouter } from "expo-router";
import { useAuthStore } from "@/stores/authStore";
import { apiClient } from "@/utils/apiClient";
import { useBiometrics } from "@/hooks/useBiometrics";

export default function LoginScreen() {
  const router = useRouter();
  const { setAuth, setBaseUrl, baseUrl } = useAuthStore();
  const { isAvailable: biometricsAvailable, biometricType, authenticate } = useBiometrics();

  const [url, setUrl] = useState(baseUrl || "https://frigate.plexserver525.com");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const handleLogin = async () => {
    if (!url.trim() || !username.trim() || !password.trim()) {
      setError("Please fill in all fields.");
      return;
    }
    setLoading(true);
    setError("");
    try {
      const trimmedUrl = url.replace(/\/$/, "");
      setBaseUrl(trimmedUrl);
      const res = await apiClient.post("/login", {
        user: username,
        password,
      });
      // Token may be in body or in Set-Cookie header
      let token = res.data?.token;
      if (!token) {
        const setCookie = res.headers?.["set-cookie"]?.join?.("") ?? res.headers?.["set-cookie"] ?? "";
        const match = typeof setCookie === "string" ? setCookie.match(/frigate_token=([^;]+)/) : null;
        token = match?.[1] ?? null;
      }
      const name = res.data?.user?.name ?? username;
      if (token) {
        setAuth(token, name);
        router.replace("/(tabs)/");
      } else {
        setError(`No token in response: ${JSON.stringify(res.data)}`);
      }
    } catch (e: unknown) {
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 401) {
        setError("Invalid username or password.");
      } else {
        setError("Could not connect to server. Check the URL.");
      }
    } finally {
      setLoading(false);
    }
  };

  const handleBiometricLogin = async () => {
    if (!url.trim()) {
      setError("Please enter your server URL first.");
      return;
    }
    setLoading(true);
    setError("");
    try {
      const trimmedUrl = url.replace(/\/$/, "");
      setBaseUrl(trimmedUrl);

      // Begin WebAuthn challenge
      const beginRes = await apiClient.post("/auth/webauthn/auth/begin", {});

      // Authenticate biometrically
      const success = await authenticate(`Sign in to Frigate with ${biometricType}`);
      if (!success) {
        setError("Biometric authentication cancelled.");
        setLoading(false);
        return;
      }

      // Complete WebAuthn (simplified — full passkey flow requires react-native-passkeys)
      const completeRes = await apiClient.post("/auth/webauthn/auth/complete", {
        challenge: beginRes.data,
      });
      const token = completeRes.data?.token;
      const name = completeRes.data?.user?.name ?? "User";
      if (token) {
        setAuth(token, name);
        router.replace("/(tabs)/");
      } else {
        setError("Face ID login failed.");
      }
    } catch {
      setError("Face ID login failed. Try password login.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <KeyboardAvoidingView
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      className="flex-1 bg-background"
    >
      <ScrollView
        contentContainerStyle={{ flexGrow: 1 }}
        keyboardShouldPersistTaps="handled"
      >
        <View className="flex-1 justify-center px-6 py-12">
          {/* Logo / Header */}
          <View className="items-center mb-10">
            <Text className="text-5xl mb-3">📷</Text>
            <Text className="text-3xl font-bold text-text-primary">Apex Sight</Text>
            <Text className="text-text-secondary mt-1">Frigate NVR Mobile Client</Text>
          </View>

          {/* Form */}
          <View className="gap-4">
            <View>
              <Text className="text-text-secondary text-sm mb-1 ml-1">Server URL</Text>
              <TextInput
                className="bg-surface border border-border rounded-xl px-4 py-3 text-text-primary text-base"
                placeholder="https://your-frigate-host.com"
                placeholderTextColor="#475569"
                value={url}
                onChangeText={setUrl}
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="url"
              />
            </View>

            <View>
              <Text className="text-text-secondary text-sm mb-1 ml-1">Username</Text>
              <TextInput
                className="bg-surface border border-border rounded-xl px-4 py-3 text-text-primary text-base"
                placeholder="admin"
                placeholderTextColor="#475569"
                value={username}
                onChangeText={setUsername}
                autoCapitalize="none"
                autoCorrect={false}
              />
            </View>

            <View>
              <Text className="text-text-secondary text-sm mb-1 ml-1">Password</Text>
              <TextInput
                className="bg-surface border border-border rounded-xl px-4 py-3 text-text-primary text-base"
                placeholder="••••••••"
                placeholderTextColor="#475569"
                value={password}
                onChangeText={setPassword}
                secureTextEntry
              />
            </View>

            {error ? (
              <Text className="text-danger text-sm text-center">{error}</Text>
            ) : null}

            <TouchableOpacity
              className="bg-primary rounded-xl py-4 items-center mt-2"
              onPress={handleLogin}
              disabled={loading}
            >
              {loading ? (
                <ActivityIndicator color="#fff" />
              ) : (
                <Text className="text-white font-semibold text-base">Sign In</Text>
              )}
            </TouchableOpacity>

            {biometricsAvailable && (
              <TouchableOpacity
                className="bg-surface border border-border rounded-xl py-4 items-center"
                onPress={handleBiometricLogin}
                disabled={loading}
              >
                <Text className="text-text-primary font-semibold text-base">
                  {biometricType === "Face ID" ? "🔒 Sign in with Face ID" : "👆 Sign in with Touch ID"}
                </Text>
              </TouchableOpacity>
            )}
          </View>

          <Text className="text-text-secondary text-xs text-center mt-8">
            Connects to your self-hosted Frigate NVR instance
          </Text>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}
