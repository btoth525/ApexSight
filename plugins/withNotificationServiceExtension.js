/**
 * Expo config plugin — Notification Service Extension
 *
 * Automatically adds the NotificationService iOS target during `expo prebuild`
 * so lock-screen push notifications can display the snapshot image.
 * Works with or without --clean; no manual Xcode steps required.
 */

const { withXcodeProject } = require("@expo/config-plugins");
const fs = require("fs");
const path = require("path");

const NSE_TARGET = "NotificationService";

function withNotificationServiceExtension(config) {
  return withXcodeProject(config, (cfg) => {
    const project = cfg.modResults;
    const projectRoot = cfg.modRequest.projectRoot;
    const iosRoot = path.join(projectRoot, "ios");
    const mainBundleId =
      cfg.ios?.bundleIdentifier ??
      config.ios?.bundleIdentifier ??
      "com.example.app";
    const nseBundleId = `${mainBundleId}.${NSE_TARGET}`;

    // ── idempotency check ────────────────────────────────────────────────────
    const existingTargets = project.pbxNativeTargetSection();
    const alreadyAdded = Object.values(existingTargets).some(
      (t) =>
        t &&
        (t.name === NSE_TARGET || t.name === `"${NSE_TARGET}"`)
    );
    if (alreadyAdded) return cfg;

    // ── copy source files into ios/NotificationService/ ──────────────────────
    const nseDir = path.join(iosRoot, NSE_TARGET);
    if (!fs.existsSync(nseDir)) fs.mkdirSync(nseDir, { recursive: true });

    const srcDir = path.join(projectRoot, "notification-service-extension");
    for (const file of ["NotificationService.swift", "Info.plist"]) {
      const dest = path.join(nseDir, file);
      if (!fs.existsSync(dest)) {
        const src = path.join(srcDir, file);
        if (fs.existsSync(src)) fs.copyFileSync(src, dest);
      }
    }

    // ── add native target (creates product, config list, target dependency,
    //    and PBXCopyFilesBuildPhase in the parent target for embedding) ───────
    const target = project.addTarget(
      NSE_TARGET,
      "app_extension",
      NSE_TARGET,
      nseBundleId
    );

    // ── add build phases to the extension target ─────────────────────────────
    // addTarget leaves buildPhases:[] — we populate it here.
    project.addBuildPhase(
      [`${NSE_TARGET}/NotificationService.swift`],
      "PBXSourcesBuildPhase",
      "Sources",
      target.uuid
    );
    project.addBuildPhase(
      [],
      "PBXResourcesBuildPhase",
      "Resources",
      target.uuid
    );
    project.addBuildPhase(
      [],
      "PBXFrameworksBuildPhase",
      "Frameworks",
      target.uuid
    );

    // ── patch build settings (addTarget names the plist wrong + lacks Swift) ─
    const buildConfigs = project.pbxXCBuildConfigurationSection();
    for (const [key, conf] of Object.entries(buildConfigs)) {
      if (key.endsWith("_comment") || !conf?.buildSettings) continue;

      // Only touch configs whose PRODUCT_NAME is our extension target
      const productName = (conf.buildSettings.PRODUCT_NAME ?? "").replace(
        /"/g,
        ""
      );
      if (productName !== NSE_TARGET) continue;

      // Fix Info.plist path (addTarget auto-generates "NotificationService/NotificationService-Info.plist")
      conf.buildSettings.INFOPLIST_FILE = `"${NSE_TARGET}/Info.plist"`;
      // Swift version (required or Xcode refuses to compile .swift files)
      conf.buildSettings.SWIFT_VERSION = "5.0";
      // Deployment target
      conf.buildSettings.IPHONEOS_DEPLOYMENT_TARGET = "13.0";
      // Bundle ID was already set by addTarget, but ensure it's correct
      conf.buildSettings.PRODUCT_BUNDLE_IDENTIFIER = `"${nseBundleId}"`;
    }

    return cfg;
  });
}

module.exports = withNotificationServiceExtension;
