import { useState, useEffect } from "react";
import * as LocalAuthentication from "expo-local-authentication";

export function useBiometrics() {
  const [isAvailable, setIsAvailable] = useState(false);
  const [biometricType, setBiometricType] = useState<string | null>(null);

  useEffect(() => {
    checkBiometrics();
  }, []);

  async function checkBiometrics() {
    const compatible = await LocalAuthentication.hasHardwareAsync();
    const enrolled = await LocalAuthentication.isEnrolledAsync();
    if (compatible && enrolled) {
      setIsAvailable(true);
      const types = await LocalAuthentication.supportedAuthenticationTypesAsync();
      if (types.includes(LocalAuthentication.AuthenticationType.FACIAL_RECOGNITION)) {
        setBiometricType("Face ID");
      } else if (types.includes(LocalAuthentication.AuthenticationType.FINGERPRINT)) {
        setBiometricType("Touch ID");
      }
    }
  }

  async function authenticate(promptMessage = "Authenticate to continue"): Promise<boolean> {
    const result = await LocalAuthentication.authenticateAsync({
      promptMessage,
      fallbackLabel: "Use Password",
      cancelLabel: "Cancel",
    });
    return result.success;
  }

  return { isAvailable, biometricType, authenticate };
}
