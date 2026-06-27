#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFileSync, execSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const BUNDLE_ID = "com.brandontoth.apexsight.native";
const APP_NAME  = "ApexSightNative";

// ── Simulator helpers ──────────────────────────────────────────────────────

function getBootedUDID(): string {
  try {
    const raw = execFileSync("xcrun", ["simctl", "list", "devices", "--json"], {
      encoding: "utf8",
    });
    const data = JSON.parse(raw) as {
      devices: Record<string, Array<{ state: string; udid: string }>>;
    };
    for (const runtime of Object.values(data.devices)) {
      for (const device of runtime) {
        if (device.state === "Booted") return device.udid;
      }
    }
  } catch {}
  return "booted";
}

function sim(...args: string[]): string {
  return execFileSync("xcrun", ["simctl", ...args], { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
}

function hasIdb(): boolean {
  try {
    execFileSync("idb", ["--help"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

// Type text safely: idb if available, otherwise clipboard paste via AppleScript.
// No shell string interpolation of user text (avoids injection).
function typeText(text: string, udid: string): string {
  if (hasIdb()) {
    execFileSync("idb", ["type", "--udid", udid, text], { stdio: "pipe" });
    return `Typed via idb: "${text}"`;
  }
  // Write to clipboard via stdin — safe, handles any characters
  execFileSync("pbcopy", [], { input: text, encoding: "utf8" });
  // Bring Simulator to front, then paste
  execFileSync("osascript", [
    "-e", "tell application \"Simulator\" to activate",
    "-e", "tell application \"System Events\" to keystroke \"v\" using {command down}",
  ]);
  return `Typed via clipboard paste: "${text}"`;
}

// Find the built .app in a DerivedData directory
function findBuiltApp(derivedData: string): string | null {
  try {
    const result = execSync(
      `find ${JSON.stringify(derivedData)} -name "${APP_NAME}.app" ` +
      `-not -path "*/PackageFrameworks/*" 2>/dev/null | head -1`,
      { encoding: "utf8" }
    ).trim();
    return result || null;
  } catch {
    return null;
  }
}

// ── Findings accumulator (persists for the lifetime of the server process) ─

interface Finding {
  screen: string;
  status: "pass" | "fail" | "warn";
  description: string;
  timestamp: string;
}

const findings: Finding[] = [];

// ── MCP Server ────────────────────────────────────────────────────────────

const server = new Server(
  { name: "apexsight-ios-tester", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "screenshot",
      description:
        "Capture a screenshot of the booted iOS Simulator and return it as an image. " +
        "Call this after every tap/swipe/navigation to see the current state.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "tap",
      description:
        "Tap at (x, y) on the simulator screen. " +
        "iPhone 16 Pro screen is 393×852 logical points. " +
        "Always call screenshot first to identify the right coordinates.",
      inputSchema: {
        type: "object",
        properties: {
          x: { type: "number", description: "Horizontal position in points" },
          y: { type: "number", description: "Vertical position in points" },
        },
        required: ["x", "y"],
      },
    },
    {
      name: "swipe",
      description:
        "Swipe from (x1,y1) to (x2,y2). Use for scrolling, pull-to-refresh, or back gestures.",
      inputSchema: {
        type: "object",
        properties: {
          x1: { type: "number" },
          y1: { type: "number" },
          x2: { type: "number" },
          y2: { type: "number" },
          duration: {
            type: "number",
            description: "Seconds. 0.3 = fast scroll, 1.0 = slow drag. Default 0.5.",
          },
        },
        required: ["x1", "y1", "x2", "y2"],
      },
    },
    {
      name: "type_text",
      description:
        "Type text into the currently focused input field. " +
        "Tap the field first so the keyboard appears, then call this.",
      inputSchema: {
        type: "object",
        properties: {
          text: { type: "string", description: "Text to enter" },
        },
        required: ["text"],
      },
    },
    {
      name: "press_button",
      description: "Press a hardware button on the simulator.",
      inputSchema: {
        type: "object",
        properties: {
          button: {
            type: "string",
            enum: ["home", "lock", "sideButton", "apple"],
            description: "'home' returns to springboard, 'lock' locks the screen",
          },
        },
        required: ["button"],
      },
    },
    {
      name: "launch_app",
      description: "Launch ApexSight on the booted simulator.",
      inputSchema: {
        type: "object",
        properties: {
          bundle_id: {
            type: "string",
            description: `Optional override. Defaults to ${BUNDLE_ID}`,
          },
        },
        required: [],
      },
    },
    {
      name: "terminate_app",
      description: "Force-quit ApexSight on the simulator.",
      inputSchema: {
        type: "object",
        properties: {
          bundle_id: {
            type: "string",
            description: `Optional override. Defaults to ${BUNDLE_ID}`,
          },
        },
        required: [],
      },
    },
    {
      name: "open_deep_link",
      description:
        "Open an apex:// deep link in the simulator. " +
        "Examples: 'apex://review?id=abc', 'apex://camera?name=front_door'",
      inputSchema: {
        type: "object",
        properties: {
          url: { type: "string", description: "Deep link URL starting with apex://" },
        },
        required: ["url"],
      },
    },
    {
      name: "list_simulators",
      description: "List all available iOS simulators with their UDID and state.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "boot_simulator",
      description: "Boot a specific simulator by UDID (from list_simulators).",
      inputSchema: {
        type: "object",
        properties: {
          udid: { type: "string", description: "Device UDID" },
        },
        required: ["udid"],
      },
    },
    {
      name: "get_console_logs",
      description:
        "Fetch recent console output from ApexSight in the simulator. " +
        "Call this when you see unexpected behavior or want to check for errors.",
      inputSchema: {
        type: "object",
        properties: {
          lines: {
            type: "number",
            description: "Number of recent lines to return (default 80)",
          },
        },
        required: [],
      },
    },
    {
      name: "build_and_install",
      description:
        "Build ApexSight from source and install it on the booted simulator. " +
        "Runs xcodegen then xcodebuild. Use after pulling code changes.",
      inputSchema: {
        type: "object",
        properties: {
          repo_path: {
            type: "string",
            description: "Absolute path to the ApexSight repo root. Auto-detected if omitted.",
          },
        },
        required: [],
      },
    },
    {
      name: "add_finding",
      description:
        "Record a test result observation. Call this for every screen/feature you test. " +
        "Findings are accumulated and written to the final report.",
      inputSchema: {
        type: "object",
        properties: {
          screen: {
            type: "string",
            description: "Screen or feature name (e.g. 'Cameras Tab', 'Login Form', 'Live Stream')",
          },
          status: {
            type: "string",
            enum: ["pass", "fail", "warn"],
            description: "pass = works as expected, fail = broken, warn = functional but UX issue",
          },
          description: {
            type: "string",
            description:
              "What you observed. For fails: what should happen vs what actually did.",
          },
        },
        required: ["screen", "status", "description"],
      },
    },
    {
      name: "generate_report",
      description:
        "Generate a markdown test report from all findings and save it to a file. " +
        "Call this at the end of the testing session.",
      inputSchema: {
        type: "object",
        properties: {
          output_path: {
            type: "string",
            description: "Save path. Defaults to ~/Desktop/apexsight-test-report.md",
          },
          summary: {
            type: "string",
            description: "Optional paragraph summarizing the overall session.",
          },
        },
        required: [],
      },
    },
    {
      name: "clear_findings",
      description: "Clear all accumulated findings to start a fresh test session.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
  ],
}));

// ── Tool handlers ──────────────────────────────────────────────────────────

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const udid = getBootedUDID();

  try {
    switch (name) {

      // ── Screenshot ────────────────────────────────────────────────────────
      case "screenshot": {
        const tmp = path.join(os.tmpdir(), `apexsight-${Date.now()}.png`);
        sim("io", udid, "screenshot", tmp);
        const data = fs.readFileSync(tmp);
        fs.unlinkSync(tmp);
        return {
          content: [{ type: "image", data: data.toString("base64"), mimeType: "image/png" }],
        };
      }

      // ── Tap ───────────────────────────────────────────────────────────────
      case "tap": {
        const { x, y } = args as { x: number; y: number };
        sim("io", udid, "tap", String(Math.round(x)), String(Math.round(y)));
        await new Promise((r) => setTimeout(r, 350));
        return { content: [{ type: "text", text: `Tapped (${x}, ${y})` }] };
      }

      // ── Swipe ─────────────────────────────────────────────────────────────
      case "swipe": {
        const { x1, y1, x2, y2, duration = 0.5 } = args as {
          x1: number; y1: number; x2: number; y2: number; duration?: number;
        };
        sim(
          "io", udid, "swipe",
          String(Math.round(x1)), String(Math.round(y1)),
          String(Math.round(x2)), String(Math.round(y2)),
          String(duration)
        );
        await new Promise((r) => setTimeout(r, Math.round(duration * 1000) + 200));
        return { content: [{ type: "text", text: `Swiped (${x1},${y1}) → (${x2},${y2})` }] };
      }

      // ── Type text ─────────────────────────────────────────────────────────
      case "type_text": {
        const { text } = args as { text: string };
        const result = typeText(text, udid);
        await new Promise((r) => setTimeout(r, 300));
        return { content: [{ type: "text", text: result }] };
      }

      // ── Hardware button ───────────────────────────────────────────────────
      case "press_button": {
        const { button } = args as { button: string };
        sim("io", udid, "button", button);
        await new Promise((r) => setTimeout(r, 500));
        return { content: [{ type: "text", text: `Pressed ${button}` }] };
      }

      // ── Launch ────────────────────────────────────────────────────────────
      case "launch_app": {
        const bundleId = (args as Record<string, string>)?.bundle_id ?? BUNDLE_ID;
        sim("launch", udid, bundleId);
        await new Promise((r) => setTimeout(r, 1800));
        return { content: [{ type: "text", text: `Launched ${bundleId}` }] };
      }

      // ── Terminate ─────────────────────────────────────────────────────────
      case "terminate_app": {
        const bundleId = (args as Record<string, string>)?.bundle_id ?? BUNDLE_ID;
        try { sim("terminate", udid, bundleId); } catch {}
        await new Promise((r) => setTimeout(r, 600));
        return { content: [{ type: "text", text: `Terminated ${bundleId}` }] };
      }

      // ── Deep link ─────────────────────────────────────────────────────────
      case "open_deep_link": {
        const { url } = args as { url: string };
        sim("openurl", udid, url);
        await new Promise((r) => setTimeout(r, 900));
        return { content: [{ type: "text", text: `Opened: ${url}` }] };
      }

      // ── List simulators ───────────────────────────────────────────────────
      case "list_simulators": {
        const raw = sim("list", "devices", "--json");
        const data = JSON.parse(raw) as {
          devices: Record<
            string,
            Array<{ name: string; udid: string; state: string; isAvailable: boolean }>
          >;
        };
        const lines: string[] = [];
        for (const [runtime, devices] of Object.entries(data.devices)) {
          const runtimeLabel = runtime
            .replace("com.apple.CoreSimulator.SimRuntime.", "")
            .replace(/-/g, " ");
          const available = devices.filter((d) => d.isAvailable);
          if (!available.length) continue;
          lines.push(`\n**${runtimeLabel}**`);
          for (const d of available) {
            const tag = d.state === "Booted" ? " ← BOOTED" : "";
            lines.push(`  ${d.name}${tag}  [${d.udid}]`);
          }
        }
        return { content: [{ type: "text", text: lines.join("\n") || "No simulators found" }] };
      }

      // ── Boot simulator ────────────────────────────────────────────────────
      case "boot_simulator": {
        const { udid: targetUdid } = args as { udid: string };
        sim("boot", targetUdid);
        await new Promise((r) => setTimeout(r, 3000));
        return { content: [{ type: "text", text: `Booted ${targetUdid}` }] };
      }

      // ── Console logs ──────────────────────────────────────────────────────
      case "get_console_logs": {
        const maxLines = ((args as Record<string, number>)?.lines) ?? 80;
        let output = "";
        try {
          // Use simctl spawn to run 'log show' inside the simulator container
          const raw = execFileSync(
            "xcrun",
            [
              "simctl", "spawn", udid,
              "log", "show",
              "--predicate", `process == "${APP_NAME}"`,
              "--last", "3m",
              "--style", "compact",
            ],
            { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
          );
          const allLines = raw.trim().split("\n");
          output = allLines.slice(-maxLines).join("\n");
        } catch {
          output = "(no logs — ensure the app is running and the simulator is booted)";
        }
        return { content: [{ type: "text", text: output || "(no recent log output)" }] };
      }

      // ── Build and install ─────────────────────────────────────────────────
      case "build_and_install": {
        // Resolve repo root: explicit arg → APEXSIGHT_REPO env → ~/ApexSight
        const repoRoot = (args as Record<string, string>)?.repo_path
          ?? process.env["APEXSIGHT_REPO"]
          ?? path.join(os.homedir(), "ApexSight");
        const nativeDir   = path.join(repoRoot, "native-ios");
        const projectFile = path.join(nativeDir, `${APP_NAME}.xcodeproj`);
        const buildDir    = path.join(os.tmpdir(), "apexsight-build");

        // Generate Xcode project from project.yml if it doesn't exist
        if (!fs.existsSync(projectFile)) {
          try {
            execFileSync("xcodegen", ["generate"], { cwd: nativeDir, encoding: "utf8" });
          } catch {
            return {
              content: [{
                type: "text",
                text: `xcodegen not found or failed. Install with: brew install xcodegen\n` +
                      `Then re-run from: ${nativeDir}`,
              }],
              isError: true,
            };
          }
        }

        // Build
        let buildLog = "";
        try {
          buildLog = execSync(
            `xcodebuild ` +
            `-project ${JSON.stringify(projectFile)} ` +
            `-scheme ${APP_NAME} ` +
            `-destination "platform=iOS Simulator,id=${udid}" ` +
            `-configuration Debug ` +
            `-derivedDataPath ${JSON.stringify(buildDir)} ` +
            `build 2>&1 | tail -30`,
            { encoding: "utf8", cwd: nativeDir }
          );
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          return { content: [{ type: "text", text: `Build failed:\n${msg}` }], isError: true };
        }

        // Find and install .app
        const appPath = findBuiltApp(buildDir);
        if (!appPath) {
          return {
            content: [{ type: "text", text: `Build succeeded but .app not found in ${buildDir}` }],
            isError: true,
          };
        }

        sim("install", udid, appPath);
        return {
          content: [{
            type: "text",
            text: `Built and installed successfully.\n\nBuild log (last 30 lines):\n${buildLog}`,
          }],
        };
      }

      // ── Add finding ───────────────────────────────────────────────────────
      case "add_finding": {
        const { screen, status, description } = args as unknown as Finding;
        findings.push({ screen, status, description, timestamp: new Date().toISOString() });
        const icon = status === "pass" ? "✅" : status === "fail" ? "❌" : "⚠️";
        return {
          content: [{
            type: "text",
            text: `${icon} [${status.toUpperCase()}] "${screen}": ${description}\nSession total: ${findings.length} findings`,
          }],
        };
      }

      // ── Generate report ───────────────────────────────────────────────────
      case "generate_report": {
        const { output_path, summary } = args as { output_path?: string; summary?: string };

        const pass  = findings.filter((f) => f.status === "pass").length;
        const fail  = findings.filter((f) => f.status === "fail").length;
        const warn  = findings.filter((f) => f.status === "warn").length;
        const total = findings.length;
        const overall = fail === 0 ? "✅ PASS" : "❌ FAIL";
        const date = new Date().toLocaleString("en-US", {
          year: "numeric", month: "long", day: "numeric",
          hour: "2-digit", minute: "2-digit",
        });

        const lines: string[] = [
          `# ApexSight UI Test Report`,
          ``,
          `**Date:** ${date}`,
          `**Overall:** ${overall}`,
          `**Results:** ${pass}/${total} passed · ${fail} failed · ${warn} warnings`,
          ``,
        ];

        if (summary) {
          lines.push(`## Summary`, ``, summary, ``);
        }

        lines.push(`## Findings by Screen`, ``);

        // Group by screen
        const byScreen = new Map<string, Finding[]>();
        for (const f of findings) {
          const g = byScreen.get(f.screen) ?? [];
          g.push(f);
          byScreen.set(f.screen, g);
        }

        for (const [screen, items] of byScreen) {
          const screenIcon = items.some((i) => i.status === "fail")
            ? "❌" : items.some((i) => i.status === "warn") ? "⚠️" : "✅";
          lines.push(`### ${screenIcon} ${screen}`, ``);
          for (const item of items) {
            const icon = item.status === "pass" ? "✅" : item.status === "fail" ? "❌" : "⚠️";
            lines.push(`- ${icon} **[${item.status.toUpperCase()}]** ${item.description}`);
          }
          lines.push(``);
        }

        if (fail > 0) {
          lines.push(`## Action Items`, ``);
          for (const f of findings.filter((f) => f.status === "fail")) {
            lines.push(`- [ ] **${f.screen}:** ${f.description}`);
          }
          lines.push(``);
        }

        if (warn > 0) {
          lines.push(`## UX Warnings`, ``);
          for (const f of findings.filter((f) => f.status === "warn")) {
            lines.push(`- **${f.screen}:** ${f.description}`);
          }
          lines.push(``);
        }

        const report = lines.join("\n");

        // Resolve save path
        const defaultPath = path.join(os.homedir(), "Desktop", "apexsight-test-report.md");
        let savePath = output_path ?? defaultPath;
        if (savePath.startsWith("~/")) savePath = path.join(os.homedir(), savePath.slice(2));
        fs.writeFileSync(savePath, report, "utf8");

        return {
          content: [{
            type: "text",
            text: `Saved to: ${savePath}\n\n---\n\n${report}`,
          }],
        };
      }

      // ── Clear findings ────────────────────────────────────────────────────
      case "clear_findings": {
        const count = findings.length;
        findings.length = 0;
        return { content: [{ type: "text", text: `Cleared ${count} findings. Ready for new session.` }] };
      }

      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    return { content: [{ type: "text", text: `Error: ${msg}` }], isError: true };
  }
});

// ── Start ──────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("ApexSight iOS Tester MCP server ready");
