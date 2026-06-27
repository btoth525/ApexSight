# ApexSight iOS Tester MCP

An MCP server that lets Claude interact directly with your iOS Simulator — take screenshots, tap, swipe, type, and generate test reports automatically.

## How it works

Claude uses this server as a set of tools:
- `screenshot` — see what's on screen right now
- `tap` / `swipe` — navigate the app
- `type_text` — enter text into fields
- `add_finding` — record pass/fail/warn observations
- `generate_report` — produce a full markdown report

## Requirements

- macOS with Xcode installed
- Node.js 18+
- ApexSight built and installed on a simulator (build from Xcode first)

## Setup (one time)

```bash
cd mcp/ios-tester
npm install
npm run build
```

## Configure Claude Code (local CLI)

Add to `~/.claude/claude.json` (or via `claude mcp add`):

```json
{
  "mcpServers": {
    "ios-tester": {
      "command": "node",
      "args": ["/absolute/path/to/ApexSight/mcp/ios-tester/dist/index.js"]
    }
  }
}
```

Or run `claude mcp add` from your terminal:

```bash
claude mcp add ios-tester node /absolute/path/to/ApexSight/mcp/ios-tester/dist/index.js
```

## Running a test session

1. Open Simulator and build/run ApexSight from Xcode
2. Open a new terminal and start Claude Code:
   ```bash
   claude
   ```
3. Tell Claude to test the app:
   ```
   Run a full UI test of ApexSight. Go through every tab, check loading states,
   test the login form, verify camera streams show a live badge, check that the
   Review tab badge updates, and generate a report when done.
   ```

Claude will navigate the app autonomously, recording findings as it goes, and save a markdown report to your Desktop.

## Optional: faster text input

Install Facebook's `idb` for more reliable text entry:

```bash
brew install facebook/fb/idb-companion
pip install fb-idb
```

Without `idb`, text input uses clipboard paste (works fine, just requires
Simulator.app to be the active window when typing).

## Tools reference

| Tool | Description |
|------|-------------|
| `screenshot` | Capture current simulator screen |
| `tap x y` | Tap at coordinates |
| `swipe x1 y1 x2 y2 [duration]` | Swipe gesture |
| `type_text text` | Type into focused field |
| `press_button home\|lock` | Hardware buttons |
| `launch_app [bundle_id]` | Launch ApexSight |
| `terminate_app [bundle_id]` | Force quit |
| `open_deep_link url` | Open apex:// deep link |
| `list_simulators` | Show available devices |
| `get_console_logs [lines]` | Get app log output |
| `add_finding screen status description` | Record a test finding |
| `generate_report [output_path] [summary]` | Save markdown report |
| `clear_findings` | Reset for new session |

## iPhone coordinates reference

iPhone 15 Pro logical resolution: **393 × 852 points**

Key areas:
- Tab bar: y ≈ 810
  - Cameras tab: x ≈ 39
  - Review tab: x ≈ 118
  - Activity tab: x ≈ 196
  - Explore tab: x ≈ 275
  - Settings tab: x ≈ 354
- Navigation bar: y ≈ 60–90
- Content area: y ≈ 100–790
- Pull-to-refresh: swipe from y=200 to y=400
