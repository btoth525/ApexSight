/**
 * Expo config plugin — Notification Service Extension
 *
 * Automatically adds the NotificationService iOS target during `expo prebuild`
 * so lock-screen push notifications can display the snapshot image.
 *
 * No manual Xcode steps required. Works with or without --clean.
 */

const {
  withXcodeProject,
  withInfoPlist,
  IOSConfig,
} = require("@expo/config-plugins");
const fs = require("fs");
const path = require("path");

const NSE_TARGET_NAME = "NotificationService";
const NSE_BUNDLE_SUFFIX = ".NotificationService";
const NSE_SOURCE_DIR = path.join(__dirname, "../notification-service-extension");

// ─── helpers ────────────────────────────────────────────────────────────────

function getBundleId(config) {
  return (
    config.ios?.bundleIdentifier ?? "com.example.app"
  );
}

/** Write extension files into ios/<TargetName>/ if not already there. */
function syncExtensionFiles(iosRoot) {
  const destDir = path.join(iosRoot, NSE_TARGET_NAME);
  if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });

  const files = ["NotificationService.swift", "Info.plist"];
  for (const file of files) {
    const src = path.join(NSE_SOURCE_DIR, file);
    const dest = path.join(destDir, file);
    if (!fs.existsSync(dest) && fs.existsSync(src)) {
      fs.copyFileSync(src, dest);
    }
  }
}

/** Return true when the named target already exists in the pbxproj. */
function targetExists(project, targetName) {
  const targets = project.pbxNativeTargetSection();
  return Object.values(targets).some(
    (t) => t && t.name && (t.name === targetName || t.name === `"${targetName}"`)
  );
}

// ─── main plugin ────────────────────────────────────────────────────────────

const withNotificationServiceExtension = (config) => {
  // Step 1: patch the Xcode project
  config = withXcodeProject(config, (cfg) => {
    const project = cfg.modResults;
    const iosRoot = path.join(cfg.modRequest.projectRoot, "ios");
    const mainBundleId = getBundleId(cfg);
    const nseBundleId = mainBundleId + NSE_BUNDLE_SUFFIX;

    // Don't add the target twice
    if (targetExists(project, NSE_TARGET_NAME)) {
      return cfg;
    }

    // Copy Swift + plist files into ios/NotificationService/
    syncExtensionFiles(iosRoot);

    // ── Add a new PBXGroup for the extension files ──────────────────────────
    const extGroup = project.addPbxGroup(
      ["NotificationService.swift", "Info.plist"],
      NSE_TARGET_NAME,
      NSE_TARGET_NAME
    );

    // Add the new group under the main group
    const groups = project.hash.project.objects["PBXGroup"];
    const mainGroupId = project.getFirstProject().firstProject.mainGroup;
    if (groups[mainGroupId]) {
      groups[mainGroupId].children.push({
        value: extGroup.uuid,
        comment: NSE_TARGET_NAME,
      });
    }

    // ── Add native target ───────────────────────────────────────────────────
    const extTarget = project.addTarget(
      NSE_TARGET_NAME,
      "app_extension",
      NSE_TARGET_NAME
    );

    // ── Build settings per configuration ───────────────────────────────────
    const configurations = project.pbxXCBuildConfigurationSection();
    const extTargetId = extTarget.uuid;

    // Find build config list for this target
    const configListId =
      project.pbxNativeTargetSection()[extTargetId]?.buildConfigurationList;

    if (configListId) {
      const configList =
        project.pbxXCConfigurationList()[configListId];
      const configIds = configList?.buildConfigurations?.map((c) => c.value) ?? [];

      for (const configId of configIds) {
        const conf = configurations[configId];
        if (!conf) continue;
        conf.buildSettings = {
          ...conf.buildSettings,
          ALWAYS_SEARCH_USER_PATHS: "NO",
          CLANG_ANALYZER_NONNULL: "YES",
          CLANG_ENABLE_MODULES: "YES",
          CLANG_ENABLE_OBJC_ARC: "YES",
          CODE_SIGN_STYLE: "Automatic",
          DEVELOPMENT_TEAM: conf.buildSettings?.DEVELOPMENT_TEAM ?? "",
          INFOPLIST_FILE: `${NSE_TARGET_NAME}/Info.plist`,
          IPHONEOS_DEPLOYMENT_TARGET: "13.0",
          MTL_ENABLE_DEBUG_INFO: "INCLUDE_SOURCE",
          PRODUCT_BUNDLE_IDENTIFIER: nseBundleId,
          PRODUCT_NAME: "$(TARGET_NAME)",
          SKIP_INSTALL: "YES",
          SWIFT_VERSION: "5.0",
          TARGETED_DEVICE_FAMILY: "1,2",
        };
      }
    }

    return cfg;
  });

  return config;
};

module.exports = withNotificationServiceExtension;
