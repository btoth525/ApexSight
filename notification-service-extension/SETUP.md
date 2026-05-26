# Notification Service Extension — Manual Setup (one time)

You only need to do this once. The extension persists across normal rebuilds.
Only if you run `npx expo prebuild --clean` will you need to redo this — so
**for future rebuilds, drop the `--clean` flag**.

## Why this is needed

iOS push notifications won't display images unless an extension processes them first.
Without this, your lock screen will show text-only notifications when the app is killed.
With this, you get the full snapshot image preview.

---

## Step 1 — Open the project

Make sure you've already run prebuild:
```bash
cd /Users/brandon/Documents/ApexSight
npx expo prebuild --platform ios   # NO --clean
open ios/ApexSight.xcworkspace
```

## Step 2 — Add a Notification Service Extension target

1. In Xcode, click **File → New → Target…**
2. In the picker, select **Notification Service Extension** (iOS section)
3. Click **Next**
4. Fill in:
   - **Product Name:** `NotificationService`
   - **Team:** select your Apple Developer team
   - **Bundle Identifier:** Xcode will auto-fill as `com.brandontoth.apexsight.NotificationService` — leave it
   - **Language:** Swift
   - **Embed in Application:** ApexSight
5. Click **Finish**
6. If it asks "Activate scheme?", click **Cancel** (we don't need to debug it)

## Step 3 — Replace the auto-generated Swift code

1. In the Xcode project navigator (left sidebar), find the new `NotificationService` folder
2. Click `NotificationService.swift` to open it
3. **Delete everything in it**
4. Open the file at `notification-service-extension/NotificationService.swift` in this project
5. Copy all the contents and paste into the Xcode file
6. Save (⌘S)

## Step 4 — Verify deployment target

1. In Xcode project navigator, click the **ApexSight** project at the top
2. In the editor, select the **NotificationService** target
3. Under **General → Minimum Deployments**, set iOS to `13.0` or higher
4. Save

## Step 5 — Build

1. Make sure you're targeting **Any iOS Device (arm64)** or your phone
2. Bump the Build number (Apex Sight target → General → Build)
3. **Product → Archive**
4. Upload to TestFlight as usual

---

## How to verify it's working

1. Install the new build via TestFlight
2. Open the app once (registers Expo Push token with your Frigate)
3. Swipe up to fully kill the app
4. Lock your phone
5. Trigger a motion alert on a camera
6. Lock screen should light up with:
   - Title: "🚶 Person detected" (or similar)
   - Body: "On driveway"
   - **Full snapshot image preview**

If you see text but no image, check Frigate logs for `Expo Push HTTP error` — that's the server side. If text + image both work, you're done.

---

## When you'd need to redo this

- If you run `npx expo prebuild --clean` (wipes ios/ folder)
- If you delete the ios/ directory manually

To avoid this: just use `npx expo prebuild --platform ios` (no `--clean`) for future builds.

## If you accidentally use --clean

It's a 5-minute redo — repeat Steps 2 and 3 above. The Swift file in this repo
stays put, just needs to be re-pasted into a fresh target.
