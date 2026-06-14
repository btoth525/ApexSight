import type React from "react";
import { useState } from "react";
import {
  ActivityIndicator,
  Image,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import CookieManager from "@react-native-cookies/cookies";
import { useRouter } from "expo-router";
import { AppleMaterial, ApplePressable, apple } from "@/components/AppleMaterial";
import { useAuthStore } from "@/stores/authStore";
import { useBiometrics } from "@/hooks/useBiometrics";
import { apiClient } from "@/utils/apiClient";
import { haptic } from "@/utils/haptics";
import { isValidServerUrl, normalizeServerUrl } from "@/utils/serverUrl";

type FieldProps = {
  icon: keyof typeof Ionicons.glyphMap;
  label: string;
  children: React.ReactNode;
};

function Field({ icon, label, children }: FieldProps) {
  return (
    <View style={{ gap: 8 }}>
      <Text style={{ color: apple.colors.secondaryLabel, fontSize: 12, fontWeight: "700" }}>
        {label}
      </Text>
      <View
        style={{
          minHeight: 52,
          borderRadius: 16,
          borderWidth: StyleSheet.hairlineWidth,
          borderColor: apple.colors.separator,
          backgroundColor: "rgba(255,255,255,0.08)",
          flexDirection: "row",
          alignItems: "center",
          gap: 10,
          paddingHorizontal: 14,
        }}
      >
        <Ionicons name={icon} size={18} color={apple.colors.tertiaryLabel} />
        {children}
      </View>
    </View>
  );
}

export default function LoginScreen() {
  const router = useRouter();
  const { setAuth, setBaseUrl, baseUrl } = useAuthStore();
  const biometrics = useBiometrics();

  const [url, setUrl] = useState(baseUrl || "");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const doLogin = async (loginUrl: string, loginUser: string, loginPass: string) => {
    const trimmedUrl = normalizeServerUrl(loginUrl);
    if (!isValidServerUrl(trimmedUrl)) {
      throw new Error("invalid-url");
    }

    await setBaseUrl(trimmedUrl);
    const res = await apiClient.post("/login", { user: loginUser.trim(), password: loginPass });
    if (res.status !== 200) throw new Error("login-failed");

    let token = "session";
    const rawCookie = res.headers?.["set-cookie"];
    if (rawCookie) {
      const cookieStr = Array.isArray(rawCookie) ? rawCookie.join("; ") : rawCookie;
      const match = cookieStr.match(/frigate_token=([^;,\s]+)/);
      if (match?.[1]) token = match[1];
    }

    if (token === "session") {
      for (let i = 0; i < 5; i++) {
        await new Promise((resolve) => setTimeout(resolve, 150));
        const cookies = await CookieManager.get(trimmedUrl);
        const val = cookies["frigate_token"]?.value;
        if (val && val.length > 10) {
          token = val;
          break;
        }
      }
    }

    const name = res.data?.user?.name ?? loginUser.trim();
    await setAuth(token, name);
    return { trimmedUrl, name, token };
  };

  const handleLogin = async () => {
    const cleanUrl = normalizeServerUrl(url);
    if (!cleanUrl || !username.trim() || !password.trim()) {
      setError("Enter your server, username, and password.");
      return;
    }

    if (!isValidServerUrl(cleanUrl)) {
      setError("Use a valid Frigate server URL.");
      return;
    }

    setLoading(true);
    setError("");
    try {
      await doLogin(cleanUrl, username, password);
      if (biometrics.isAvailable) {
        biometrics.saveCredentials(cleanUrl, username.trim(), password).catch(() => {});
      }
      haptic.success();
      router.replace("/browser");
    } catch (e: unknown) {
      haptic.error();
      const err = e as { message?: string; response?: { status?: number } };
      if (err.message === "invalid-url") setError("Use a valid Frigate server URL.");
      else if (err.response?.status === 401) setError("Invalid username or password.");
      else setError("Could not connect to Frigate.");
    } finally {
      setLoading(false);
    }
  };

  const handleFaceID = async () => {
    setLoading(true);
    setError("");
    try {
      const creds = await biometrics.getCredentials();
      if (!creds) {
        setError("Face ID was not able to unlock saved credentials.");
        return;
      }
      await doLogin(creds.url, creds.username, creds.password);
      haptic.success();
      router.replace("/browser");
    } catch (e: unknown) {
      haptic.error();
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 401) setError("Saved credentials need to be updated.");
      else setError("Could not connect to Frigate.");
    } finally {
      setLoading(false);
    }
  };

  const showFaceID = biometrics.isAvailable && biometrics.hasStoredCredentials;

  return (
    <KeyboardAvoidingView
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      style={{ flex: 1, backgroundColor: apple.colors.background }}
    >
      <StatusBar barStyle="light-content" />
      <ScrollView
        contentContainerStyle={{ flexGrow: 1, paddingHorizontal: 22, paddingVertical: 36 }}
        keyboardShouldPersistTaps="handled"
      >
        <View style={{ flex: 1, justifyContent: "center", gap: 26 }}>
          <View style={{ alignItems: "center" }}>
            <Image
              source={require("@/assets/icon.png")}
              style={{
                width: 104,
                height: 104,
                borderRadius: 26,
                marginBottom: 18,
                borderWidth: 1,
                borderColor: "rgba(255,255,255,0.16)",
              }}
              resizeMode="cover"
            />
            <Text style={{ color: apple.colors.label, fontSize: 34, fontWeight: "800" }}>Apex</Text>
            <Text style={{ color: apple.colors.secondaryLabel, fontSize: 15, marginTop: 6 }}>
              Native Frigate viewer for iPhone
            </Text>
          </View>

          <AppleMaterial
            tint="systemChromeMaterialDark"
            intensity={88}
            contentStyle={{
              padding: 18,
              gap: 15,
            }}
          >
            {showFaceID ? (
              <ApplePressable
                onPress={handleFaceID}
                disabled={loading}
                accessibilityLabel={`Sign in with ${biometrics.biometricType ?? "Face ID"}`}
                style={{
                  minHeight: 54,
                  borderRadius: 18,
                  backgroundColor: "rgba(255,255,255,0.14)",
                  borderWidth: 1,
                  borderColor: "rgba(255,255,255,0.16)",
                  flexDirection: "row",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: 10,
                }}
              >
                <Ionicons name="scan-outline" size={22} color={apple.colors.cyan} />
                <Text style={{ color: apple.colors.label, fontWeight: "800", fontSize: 16 }}>
                  Sign in with {biometrics.biometricType ?? "Face ID"}
                </Text>
              </ApplePressable>
            ) : null}

            {showFaceID ? (
              <View style={{ flexDirection: "row", alignItems: "center", gap: 10, paddingVertical: 2 }}>
                <View style={{ flex: 1, height: 1, backgroundColor: "rgba(255,255,255,0.1)" }} />
                <Text style={{ color: apple.colors.tertiaryLabel, fontSize: 12, fontWeight: "700" }}>
                  Manual sign in
                </Text>
                <View style={{ flex: 1, height: 1, backgroundColor: "rgba(255,255,255,0.1)" }} />
              </View>
            ) : null}

            <Field icon="globe-outline" label="Server">
              <TextInput
                style={{ flex: 1, color: "#ffffff", fontSize: 15, paddingVertical: 14 }}
                placeholder="frigate.example.com"
                placeholderTextColor="rgba(255,255,255,0.34)"
                value={url}
                onChangeText={(value) => {
                  setUrl(value);
                  if (error) setError("");
                }}
                onBlur={() => setUrl((value) => normalizeServerUrl(value))}
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="url"
                textContentType="URL"
              />
            </Field>

            <Field icon="person-outline" label="Username">
              <TextInput
                style={{ flex: 1, color: "#ffffff", fontSize: 15, paddingVertical: 14 }}
                placeholder="admin"
                placeholderTextColor="rgba(255,255,255,0.34)"
                value={username}
                onChangeText={(value) => {
                  setUsername(value);
                  if (error) setError("");
                }}
                autoCapitalize="none"
                autoCorrect={false}
                textContentType="username"
              />
            </Field>

            <Field icon="lock-closed-outline" label="Password">
              <TextInput
                style={{ flex: 1, color: "#ffffff", fontSize: 15, paddingVertical: 14 }}
                placeholder="Password"
                placeholderTextColor="rgba(255,255,255,0.34)"
                value={password}
                onChangeText={(value) => {
                  setPassword(value);
                  if (error) setError("");
                }}
                secureTextEntry={!showPassword}
                textContentType="password"
              />
              <ApplePressable
                onPress={() => setShowPassword((value) => !value)}
                accessibilityLabel={showPassword ? "Hide password" : "Show password"}
                style={{ width: 34, height: 34, borderRadius: 17, alignItems: "center", justifyContent: "center" }}
              >
                <Ionicons
                  name={showPassword ? "eye-off-outline" : "eye-outline"}
                  size={18}
                  color={apple.colors.secondaryLabel}
                />
              </ApplePressable>
            </Field>

            {error ? (
              <View
                style={{
                  borderRadius: 14,
                  backgroundColor: "rgba(255,59,48,0.13)",
                  borderWidth: 1,
                  borderColor: "rgba(255,59,48,0.22)",
                  paddingHorizontal: 12,
                  paddingVertical: 10,
                  flexDirection: "row",
                  alignItems: "center",
                  gap: 8,
                }}
              >
                <Ionicons name="alert-circle" size={16} color="#ff9f9a" />
                <Text style={{ flex: 1, color: "#ffd3d0", fontSize: 13, fontWeight: "600" }}>
                  {error}
                </Text>
              </View>
            ) : null}

            <ApplePressable
              style={{
                minHeight: 56,
                backgroundColor: apple.colors.cyan,
                borderRadius: 18,
                alignItems: "center",
                justifyContent: "center",
                marginTop: 2,
                shadowColor: apple.colors.cyan,
                shadowOpacity: 0.28,
                shadowRadius: 18,
                shadowOffset: { width: 0, height: 8 },
              }}
              onPress={handleLogin}
              disabled={loading}
              accessibilityLabel="Sign in"
            >
              {loading ? (
                <ActivityIndicator color="#061016" />
              ) : (
                <Text style={{ color: "#061016", fontWeight: "900", fontSize: 16 }}>Sign In</Text>
              )}
            </ApplePressable>
          </AppleMaterial>

          <Text style={{ color: apple.colors.tertiaryLabel, fontSize: 12, textAlign: "center" }}>
            Secured locally with iOS keychain storage
          </Text>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}
