/**
 * withApexDoorbell — custom Expo config plugin
 *
 * react-native-voip-push-notification + react-native-callkeep require native
 * AppDelegate wiring that no existing config plugin provides. Without it, iOS
 * 13+ terminates the app when a VoIP push arrives (and the partial/unwired
 * native module can crash on launch). This plugin injects, at prebuild time:
 *
 *   1. PushKit + RNVoipPushNotification + RNCallKeep imports
 *   2. [RNVoipPushNotificationManager voipRegistration] in didFinishLaunching
 *   3. The PKPushRegistry delegate methods, including the critical
 *      reportNewIncomingCall call that MUST run synchronously in the push
 *      handler on iOS 13+.
 *   4. aps-environment entitlement + voip/audio background modes.
 *
 * The VoIP push payload (sent by frigate-integration/voip_push.py) is:
 *   { "uuid": "...", "camera": "doorbell", "caller": "Front Door" }
 */

const {
  withAppDelegate,
  withInfoPlist,
  withEntitlementsPlist,
} = require("@expo/config-plugins");
const {
  mergeContents,
} = require("@expo/config-plugins/build/utils/generateCode");

// ── Native code snippets ─────────────────────────────────────────────────────

const IMPORTS = `#import <PushKit/PushKit.h>
#import "RNVoipPushNotificationManager.h"
#import "RNCallKeep.h"`;

const VOIP_REGISTRATION = `  // Apex: set up CallKit + VoIP push before the JS bridge is ready, so a
  // cold-start VoIP push can report to CallKit synchronously (required on iOS 13+).
  [RNCallKeep setup:@{
    @"appName": @"Apex",
    @"supportsVideo": @YES,
    @"maximumCallGroups": @1,
    @"maximumCallsPerCallGroup": @1,
  }];
  [RNVoipPushNotificationManager voipRegistration];`;

const PUSHKIT_DELEGATE = `
#pragma mark - Apex VoIP Push (doorbell)

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(PKPushType)type
{
  [RNVoipPushNotificationManager didUpdatePushCredentials:credentials forType:(NSString *)type];
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type
{
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion
{
  NSDictionary *p = payload.dictionaryPayload;
  NSString *uuid   = p[@"uuid"]   ?: [[NSUUID UUID] UUIDString];
  NSString *caller = p[@"caller"] ?: @"Front Door";
  NSString *camera = p[@"camera"] ?: @"doorbell";

  // iOS 13+ REQUIRES reporting to CallKit synchronously in this handler,
  // otherwise the system terminates the app.
  [RNCallKeep reportNewIncomingCall:uuid
                             handle:camera
                         handleType:@"generic"
                           hasVideo:YES
                localizedCallerName:caller
                    supportsHolding:NO
                       supportsDTMF:NO
                   supportsGrouping:NO
                 supportsUngrouping:NO
                        fromPushKit:YES
                            payload:p
              withCompletionHandler:nil];

  // Forward the payload to JS so the camera name is available on answer.
  [RNVoipPushNotificationManager didReceiveIncomingPushWithPayload:payload forType:(NSString *)type];

  completion();
}
`;

// ── AppDelegate modifier ─────────────────────────────────────────────────────

function withDoorbellAppDelegate(config) {
  return withAppDelegate(config, (cfg) => {
    let contents = cfg.modResults.contents;

    if (cfg.modResults.language !== "objc" && cfg.modResults.language !== "objcpp") {
      throw new Error(
        `withApexDoorbell: expected an Objective-C AppDelegate but got '${cfg.modResults.language}'. ` +
          `This plugin targets Expo SDK 51.`,
      );
    }

    // 1. Imports — right after #import "AppDelegate.h"
    contents = mergeContents({
      tag: "apex-doorbell-imports",
      src: contents,
      newSrc: IMPORTS,
      anchor: /#import "AppDelegate\.h"/,
      offset: 1,
      comment: "//",
    }).contents;

    // 2. voipRegistration — before the `return [super application:...]` line
    contents = mergeContents({
      tag: "apex-doorbell-voipreg",
      src: contents,
      newSrc: VOIP_REGISTRATION,
      anchor: /return \[super application:application didFinishLaunchingWithOptions:launchOptions\];/,
      offset: 0,
      comment: "//",
    }).contents;

    // 3. PKPushRegistry delegate methods — before the final @end
    contents = mergeContents({
      tag: "apex-doorbell-pushkit",
      src: contents,
      newSrc: PUSHKIT_DELEGATE,
      anchor: /@end[\s]*$/,
      offset: 0,
      comment: "//",
    }).contents;

    cfg.modResults.contents = contents;
    return cfg;
  });
}

// ── Info.plist: ensure voip + audio background modes ─────────────────────────

function withDoorbellBackgroundModes(config) {
  return withInfoPlist(config, (cfg) => {
    const modes = cfg.modResults.UIBackgroundModes || [];
    for (const m of ["voip", "audio"]) {
      if (!modes.includes(m)) modes.push(m);
    }
    cfg.modResults.UIBackgroundModes = modes;
    return cfg;
  });
}

// ── Entitlements: aps-environment for push ───────────────────────────────────

function withDoorbellEntitlements(config) {
  return withEntitlementsPlist(config, (cfg) => {
    if (!cfg.modResults["aps-environment"]) {
      // EAS / App Store builds use "production"; this is also accepted by
      // TestFlight. Development builds get remapped automatically by Xcode.
      cfg.modResults["aps-environment"] = "production";
    }
    return cfg;
  });
}

module.exports = function withApexDoorbell(config) {
  config = withDoorbellBackgroundModes(config);
  config = withDoorbellEntitlements(config);
  config = withDoorbellAppDelegate(config);
  return config;
};
