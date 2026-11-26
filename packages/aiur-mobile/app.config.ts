import type { ExpoConfig } from "expo/config";

const config: ExpoConfig = {
  name: "aiur",
  slug: "aiur-mobile",
  version: "0.1.0",
  icon: "./assets/aiur-logo.png",
  ios: { bundleIdentifier: "dev.aiur.mobile", supportsTablet: false },
  android: { package: "dev.aiur.mobile" },
  plugins: [
    ["expo-build-properties", {
      ios: { deploymentTarget: "17.0" },
      android: { minSdkVersion: 29 },
    }],
  ],
};

export default config;
