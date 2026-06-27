# ApexSight iOS Tester MCP

MCP server that gives Claude direct access to your iOS Simulator — screenshots, taps,
swipes, text input, console logs, and an auto-generated test report.

---

## Step 1 — Build the Xcode project

The project uses [xcodegen](https://github.com/yonaskolb/XcodeGen) to generate the
`.xcodeproj` from `project.yml`. Do this once, and again whenever `project.yml` changes.

```bash
# Install prerequisites (once)
brew install xcodegen

# Generate the Xcode project
cd ~/path/to/ApexSight/native-ios
xcodegen generate

# Open in Xcode and hit Run (⌘R) — easiest first-time setup
open ApexSightNative.xcodeproj
```

**Or build entirely from the terminal:**

```bash
cd ~/path/to/ApexSight/native-ios

# List available simulators to pick a destination
xcrun simctl list devices available

# Build and install in one command (replace the simulator name as needed)
xcodebuild \
  -project ApexSightNative.xcodeproj \
  -scheme ApexSightNative \
  -destination "platform=iOS Simulator,name=iPhone 16 Pro" \
  -configuration Debug \
  build

# Optional: prettier output (brew install xcpretty)
xcodebuild ... | xcpretty
```

**Boot the simulator and launch the app from terminal:**

```bash
# Boot a simulator by name
xcrun simctl boot "iPhone 16 Pro"

# Open the Simulator app so you can see the screen
open -a Simulator

# Install the built app (path from xcodebuild output, usually in ~/Library/Developer/Xcode/DerivedData)
xcrun simctl install booted /path/to/ApexSightNative.app

# Launch it
xcrun simctl launch booted com.brandontoth.apexsight.native
```

---

## Step 2 — Build the MCP server

```bash
cd ~/path/to/ApexSight/mcp/ios-tester
npm install
npm run build
```

---

## Step 3 — Connect to Claude Code Desktop

**Option A — command line (fastest):**
```bash
claude mcp add ios-tester node "$(pwd)/dist/index.js"
```

**Option B — edit `~/.claude/claude.json` manually:**
```json
{
  "mcpServers": {
    "ios-tester": {
      "command": "node",
      "args": ["/Users/YOUR_USERNAME/path/to/ApexSight/mcp/ios-tester/dist/index.js"],
      "env": {
        "APEXSIGHT_REPO": "/Users/YOUR_USERNAME/path/to/ApexSight"
      }
    }
  }
}
```

Set `APEXSIGHT_REPO` so Claude knows where the repo is when using `build_and_install`.

**Verify it's connected:**
```bash
claude mcp list
# should show: ios-tester ✓ connected
```

---

## Step 4 — Run a test session

1. Boot a simulator and run ApexSight from Xcode (or Step 1 terminal commands above)
2. Open Claude Code Desktop or run `claude` in your terminal
3. Tell Claude what to test:

```
Test the full ApexSight app. Go through every tab:
- Cameras: check live streams load, badge shows when live
- Review: verify unread count badge in tab bar, pull-to-refresh works
- Activity: check event rows render correctly
- Explore: search for "person", verify results appear
- Settings: open Notifications settings, check background is correct

Record a finding for each screen (pass/fail/warn) and generate
a report at the end saved to ~/Desktop/apexsight-test-report.md
```

Claude will autonomously navigate, take screenshots, record findings, and produce the report.

---

## Tools reference

| Tool | What it does |
|------|-------------|
| `screenshot` | Capture current screen (image returned) |
| `tap x y` | Tap at coordinates |
| `swipe x1 y1 x2 y2 [duration]` | Swipe gesture |
| `type_text text` | Type into focused field |
| `press_button home\|lock\|sideButton` | Hardware buttons |
| `launch_app [bundle_id]` | Launch ApexSight |
| `terminate_app [bundle_id]` | Force quit |
| `open_deep_link url` | Open `apex://` deep link |
| `list_simulators` | Show all available devices |
| `boot_simulator udid` | Boot a specific device |
| `get_console_logs [lines]` | Fetch app log output |
| `build_and_install [repo_path]` | Build from source, install on simulator |
| `add_finding screen status description` | Record pass/fail/warn |
| `generate_report [output_path] [summary]` | Save markdown report |
| `clear_findings` | Reset for a new session |

---

## iPhone coordinates cheat sheet

iPhone 16 Pro logical resolution: **393 × 852 points**

| Area | X | Y |
|------|---|---|
| Status bar | — | ~28 |
| Navigation bar title | ~196 | ~60 |
| Tab bar — Cameras | ~39 | ~815 |
| Tab bar — Review | ~118 | ~815 |
| Tab bar — Activity | ~196 | ~815 |
| Tab bar — Explore | ~275 | ~815 |
| Tab bar — Settings | ~354 | ~815 |
| Content area (top) | — | ~100 |
| Content area (center) | — | ~426 |
| Pull-to-refresh | ~196 | swipe 150→380 |
| Back gesture | swipe 10,400→200,400 | — |

---

## Optional: faster text input

Install Facebook's `idb` for reliable text entry without clipboard:

```bash
brew install facebook/fb/idb-companion
pip3 install fb-idb
```

Without idb, the server uses clipboard paste (writes text → `pbcopy`, then Cmd+V into
Simulator). This works fine as long as the Simulator window is accessible.
