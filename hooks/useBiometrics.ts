import { useState, useEffect, useCallback } from "react";
import * as LocalAuthentication from "expo-local-authentication";
import * as SecureStore from "expo-secure-store";

const BIO_USERNAME_KEY = "bio_username";
const BIO_PASSWORD_KEY = "bio_password";
const BIO_URL_KEY      = "bio_url";

export function useBiometrics() {
  const [isAvailable, setIsAvailable] = useState(false);
  const [biometricType, setBiometricType] = useState<string | null>(null);
  const [hasStoredCredentials, setHasStoredCredentials] = useState(false);

  useEffect(() => {
    (async () => {
      const compatible = await LocalAuthentication.hasHardwareAsync();
      const enrolled = await LocalAuthentication.isEnrolledAsync();
      if (compatible && enrolled) {
        setIsAvailable(true);
        const types = await LocalAuthentication.supportedAuthenticationTypesAsync();
        if (types.includes(LocalAuthentication.AuthenticationType.FACIAL_RECOGNITION)) {
          setBiometricType("Face ID");
        } else if (types.includes(LocalAuthentication.AuthenticationType.FINGERPRINT)) {
          setBiometricType("Touch ID");
        } else {
          setBiometricType("Biometric");
        }
      }
      const stored = await SecureStore.getItemAsync(BIO_USERNAME_KEY);
      setHasStoredCredentials(!!stored);
    })();
  }, []);

  const authenticate = useCallback(async (promptMessage = "Authenticate to continue"): Promise<boolean> => {
    const result = await LocalAuthentication.authenticateAsync({
      promptMessage,
      fallbackLabel: "Use Password",
      cancelLabel: "Cancel",
      disableDeviceFallback: false,
    });
    return result.success;
  }, []);

  // Save credentials behind biometric protection so next time the user can
  // unlock them with Face ID and we replay the normal /api/login flow.
  const saveCredentials = useCallback(async (url: string, username: string, password: string) => {
    await Promise.all([
      SecureStore.setItemAsync(BIO_URL_KEY, url),
      SecureStore.setItemAsync(BIO_USERNAME_KEY, username),
      SecureStore.setItemAsync(BIO_PASSWORD_KEY, password, {
        requireAuthentication: true,
        authenticationPrompt: "Confirm to enable Face ID login",
      }),
    ]);
    setHasStoredCredentials(true);
  }, []);

  const getCredentials = useCallback(async (): Promise<{ url: string; username: string; password: string } | null> => {
    try {
      const [url, username, password] = await Promise.all([
        SecureStore.getItemAsync(BIO_URL_KEY),
        SecureStore.getItemAsync(BIO_USERNAME_KEY),
        SecureStore.getItemAsync(BIO_PASSWORD_KEY, {
          requireAuthentication: true,
          authenticationPrompt: `Sign in with ${biometricType ?? "biometrics"}`,
        }),
      ]);
      if (!url || !username || !password) return null;
      return { url, username, password };
    } catch {
      return null;
    }
  }, [biometricType]);

  const clearCredentials = useCallback(async () => {
    await Promise.all([
      SecureStore.deleteItemAsync(BIO_USERNAME_KEY),
      SecureStore.deleteItemAsync(BIO_PASSWORD_KEY),
      SecureStore.deleteItemAsync(BIO_URL_KEY),
    ]);
    setHasStoredCredentials(false);
  }, []);

  return {
    isAvailable,
    biometricType,
    hasStoredCredentials,
    authenticate,
    saveCredentials,
    getCredentials,
    clearCredentials,
  };
}
