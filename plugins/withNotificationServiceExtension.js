/**
 * Expo config plugin — Notification Service Extension + App Group
 *
 * 1. Adds the NotificationService iOS extension target so rich push
 *    notifications (with snapshot images) work on the lock screen.
 * 2. Wires up an App Group (group.com.brandontoth.apexsight) on both
 *    the main app and the extension so the extension can read the
 *    frigate_token written by the main app to authenticate image downloads.
 * 3. Injects a tiny ObjC native module (ApexAppGroup) into the main app
 *    so JS can write to the shared App Group UserDefaults.
 */

const {
  withXcodeProject,
  withEntitlementsPlist,
} = require("@expo/config-plugins");
const fs = require("fs");
const path = require("path");

const NSE_TARGET  = "NotificationService";
const APP_GROUP   = "group.com.brandontoth.apexsight";
const MODULE_FILE = "ApexAppGroup.m";

// ── ObjC native module source ────────────────────────────────────────────────
// Exposes NativeModules.ApexAppGroup.setItem / removeItem to JS.
// Writes to the shared App Group UserDefaults so the extension can read them.
const OBJC_MODULE = `\
#import <React/RCTBridgeModule.h>
#import <Foundation/Foundation.h>

@interface ApexAppGroup : NSObject <RCTBridgeModule>
@end

@implementation ApexAppGroup

RCT_EXPORT_MODULE()

static NSString *const kGroup = @"${APP_GROUP}";

RCT_EXPORT_METHOD(setItem:(NSString *)key value:(NSString *)value) {
  NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kGroup];
  [ud setObject:value forKey:key];
  [ud synchronize];
}

RCT_EXPORT_METHOD(removeItem:(NSString *)key) {
  NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kGroup];
  [ud removeObjectForKey:key];
  [ud synchronize];
}

+ (BOOL)requiresMainQueueSetup { return NO; }

@end
`;

// ── Step 1: App Group entitlement on the main app ────────────────────────────
function withMainAppGroup(config) {
  return withEntitlementsPlist(config, (cfg) => {
    const key = "com.apple.security.application-groups";
    if (!Array.isArray(cfg.modResults[key])) cfg.modResults[key] = [];
    if (!cfg.modResults[key].includes(APP_GROUP)) {
      cfg.modResults[key].push(APP_GROUP);
    }
    return cfg;
  });
}

// ── Step 2: Xcode project modifications ─────────────────────────────────────
function withXcodeChanges(config) {
  return withXcodeProject(config, (cfg) => {
    const project    = cfg.modResults;
    const projectRoot = cfg.modRequest.projectRoot;
    const iosRoot    = path.join(projectRoot, "ios");
    const mainBundleId =
      cfg.ios?.bundleIdentifier ??
      config.ios?.bundleIdentifier ??
      "com.example.app";
    const nseBundleId = `${mainBundleId}.${NSE_TARGET}`;

    // ── A. Inject ObjC native module into the main app ───────────────────────
    const mainAppDir = path.join(iosRoot, "ApexSight");
    const moduleFile = path.join(mainAppDir, MODULE_FILE);
    // Always overwrite so updates to the source are picked up on each prebuild
    if (fs.existsSync(mainAppDir)) {
      fs.writeFileSync(moduleFile, OBJC_MODULE);
      // Add to the main target's Sources build phase (first target = ApexSight)
      const alreadyInProject = Object.values(
        project.pbxFileReferenceSection()
      ).some((ref) => ref && ref.path === `"ApexSight/${MODULE_FILE}"`);
      if (!alreadyInProject) {
        project.addSourceFile(
          `ApexSight/${MODULE_FILE}`,
          { target: project.getFirstTarget().uuid }
        );
      }
    }

    // ── B. Add extension target (idempotent) ──────────────────────────────────
    const existingTargets = project.pbxNativeTargetSection();
    const alreadyAdded = Object.values(existingTargets).some(
      (t) => t && (t.name === NSE_TARGET || t.name === `"${NSE_TARGET}"`)
    );

    if (!alreadyAdded) {
      // Copy Swift + Info.plist + entitlements into ios/NotificationService/
      const nseDir = path.join(iosRoot, NSE_TARGET);
      if (!fs.existsSync(nseDir)) fs.mkdirSync(nseDir, { recursive: true });

      const srcDir = path.join(projectRoot, "notification-service-extension");
      for (const file of [
        "NotificationService.swift",
        "Info.plist",
        "NotificationService.entitlements",
      ]) {
        const dest = path.join(nseDir, file);
        const src  = path.join(srcDir, file);
        if (!fs.existsSync(dest) && fs.existsSync(src)) {
          fs.copyFileSync(src, dest);
        }
      }

      // Add the native target
      const target = project.addTarget(
        NSE_TARGET,
        "app_extension",
        NSE_TARGET,
        nseBundleId
      );

      // Add build phases (addTarget leaves buildPhases:[])
      project.addBuildPhase(
        [`${NSE_TARGET}/NotificationService.swift`],
        "PBXSourcesBuildPhase",
        "Sources",
        target.uuid
      );
      project.addBuildPhase([], "PBXResourcesBuildPhase",  "Resources",  target.uuid);
      project.addBuildPhase([], "PBXFrameworksBuildPhase", "Frameworks", target.uuid);

      // Patch build settings for this target
      const buildConfigs = project.pbxXCBuildConfigurationSection();
      for (const [key, conf] of Object.entries(buildConfigs)) {
        if (key.endsWith("_comment") || !conf?.buildSettings) continue;
        const productName = (conf.buildSettings.PRODUCT_NAME ?? "").replace(/"/g, "");
        if (productName !== NSE_TARGET) continue;

        conf.buildSettings.INFOPLIST_FILE            = `"${NSE_TARGET}/Info.plist"`;
        conf.buildSettings.SWIFT_VERSION             = "5.0";
        conf.buildSettings.IPHONEOS_DEPLOYMENT_TARGET = "13.0";
        conf.buildSettings.PRODUCT_BUNDLE_IDENTIFIER = `"${nseBundleId}"`;
        // Wire up entitlements file (gives extension access to the App Group)
        conf.buildSettings.CODE_SIGN_ENTITLEMENTS =
          `"${NSE_TARGET}/NotificationService.entitlements"`;
      }
    } else {
      // Target already exists — still copy files in case Swift code changed
      const nseDir = path.join(iosRoot, NSE_TARGET);
      const srcDir = path.join(projectRoot, "notification-service-extension");
      for (const file of [
        "NotificationService.swift",
        "Info.plist",
        "NotificationService.entitlements",
      ]) {
        const dest = path.join(nseDir, file);
        const src  = path.join(srcDir, file);
        if (fs.existsSync(src)) fs.copyFileSync(src, dest);
      }
    }

    return cfg;
  });
}

// ── Compose both mods ────────────────────────────────────────────────────────
function withNotificationServiceExtension(config) {
  config = withMainAppGroup(config);
  config = withXcodeChanges(config);
  return config;
}

module.exports = withNotificationServiceExtension;
