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

// ── Simulator helpers ──────────────────────────────────────────────────────

function getBootedUDID(): string {
  try {
    const raw = execFileSync("xcrun", ["simctl", "list", "devices", "--json"], {
      encoding: "utf8",
    });
    const data = JSON.parse(raw) as { devices: Record<string, Array<{ state: string; udid: string }>> };
    for (const runtime of Object.values(data.devices)) {
      for (const device of runtime) {
        if (device.state === "Booted") return device.udid;
      }
    }
  } catch {}
  return "booted";
}

function sim(...args: string[]): string {
  return execFileSync("xcrun", ["simctl", ...args], { encoding: "utf8" });
}

function hasIdb(): boolean {
  try {
    execFileSync("idb", ["--help"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

// Type text: try idb first, fall back to clipboard + Cmd+V via AppleScript
function typeText(text: string, udid: string): string {
  if (hasIdb()) {
    execFileSync("idb", ["type", "--udid", udid, text], { encoding: "utf8" });
    return `Typed via idb: "${text}"`;
  }
  // Clipboard approach — requires Simulator.app to be the frontmost window
  execSync(`printf %s ${JSON.stringify(text)} | pbcopy`);
  execSync(`osascript -e 'tell application "Simulator" to activate'`);
  execSync(
    `osascript -e 'tell application "System Events" to keystroke "v" using {command down}'`
  );
  return `Typed via clipboard paste: "${text}"`;
}

// ── Findings accumulator (in-memory for this session) ────────────────────

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
        "Always call this after any tap/swipe/navigation to see the current state.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "tap",
      description:
        "Tap at (x, y) on the simulator screen. " +
        "iPhone 15 Pro screen is 393×852 logical points. " +
        "Call screenshot first to determine the right coordinates.",
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
      description: "Swipe from (x1,y1) to (x2,y2). Use for scroll, pull-to-refresh, or tab switching.",
      inputSchema: {
        type: "object",
        properties: {
          x1: { type: "number" },
          y1: { type: "number" },
          x2: { type: "number" },
          y2: { type: "number" },
          duration: {
            type: "number",
            description: "Duration in seconds. Use 0.3 for fast scroll, 1.0 for slow drag.",
            default: 0.5,
          },
        },
        required: ["x1", "y1", "x2", "y2"],
      },
    },
    {
      name: "type_text",
      description:
        "Type text into the currently focused input field. " +
        "Tap the field first, wait for keyboard to appear, then call this.",
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
            description: "'home' to go to springboard, 'lock' to lock screen",
          },
        },
        required: ["button"],
      },
    },
    {
      name: "launch_app",
      description: "Launch ApexSight (or another app by bundle ID) on the booted simulator.",
      inputSchema: {
        type: "object",
        properties: {
          bundle_id: {
            type: "string",
            description: `Bundle ID to launch. Defaults to ${BUNDLE_ID}`,
          },
        },
        required: [],
      },
    },
    {
      name: "terminate_app",
      description: "Terminate (force-quit) ApexSight on the simulator.",
      inputSchema: {
        type: "object",
        properties: {
          bundle_id: { type: "string", description: `Defaults to ${BUNDLE_ID}` },
        },
        required: [],
      },
    },
    {
      name: "open_deep_link",
      description:
        "Open an 'apex://' deep link in the simulator. " +
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
      description: "List all available iOS simulators and their current state.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "get_console_logs",
      description:
        "Fetch recent console output from ApexSight running in the simulator. " +
        "Use this when you see an error or unexpected behavior to get the stack trace.",
      inputSchema: {
        type: "object",
        properties: {
          lines: { type: "number", description: "How many recent lines to return (default 60)", default: 60 },
        },
        required: [],
      },
    },
    {
      name: "add_finding",
      description:
        "Record a test finding. Call this whenever you observe a pass, fail, or warning " +
        "while testing a screen or feature. These are collected and included in the final report.",
      inputSchema: {
        type: "object",
        properties: {
          screen: { type: "string", description: "Which screen or feature you tested (e.g. 'Cameras Tab', 'Login Form')" },
          status: {
            type: "string",
            enum: ["pass", "fail", "warn"],
            description: "'pass' = works correctly, 'fail' = broken, 'warn' = works but has a UX issue",
          },
          description: {
            type: "string",
            description: "Concise description of what you observed. For fails, include what should happen vs what did.",
          },
        },
        required: ["screen", "status", "description"],
      },
    },
    {
      name: "generate_report",
      description:
        "Generate a full markdown test report from all findings recorded this session " +
        "and save it to a file. Call this at the end of a testing run.",
      inputSchema: {
        type: "object",
        properties: {
          output_path: {
            type: "string",
            description: "Where to save the report (e.g. ~/Desktop/apexsight-test-report.md). Defaults to ~/Desktop.",
          },
          summary: {
            type: "string",
            description: "Optional paragraph summarizing the overall test session.",
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

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const udid = getBootedUDID();

  try {
    switch (name) {
      // ── Screenshot ──────────────────────────────────────────────────────
      case "screenshot": {
        const tmp = path.join(os.tmpdir(), `apexsight-sim-${Date.now()}.png`);
        sim("io", udid, "screenshot", tmp);
        const data = fs.readFileSync(tmp);
        fs.unlinkSync(tmp);
        return {
          content: [
            { type: "image", data: data.toString("base64"), mimeType: "image/png" },
          ],
        };
      }

      // ── Tap ─────────────────────────────────────────────────────────────
      case "tap": {
        const { x, y } = args as { x: number; y: number };
        sim("io", udid, "tap", String(Math.round(x)), String(Math.round(y)));
        // Small pause so the UI settles before next action
        await new Promise((r) => setTimeout(r, 350));
        return { content: [{ type: "text", text: `Tapped (${x}, ${y})` }] };
      }

      // ── Swipe ───────────────────────────────────────────────────────────
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

      // ── Type text ───────────────────────────────────────────────────────
      case "type_text": {
        const { text } = args as { text: string };
        const result = typeText(text, udid);
        await new Promise((r) => setTimeout(r, 300));
        return { content: [{ type: "text", text: result }] };
      }

      // ── Hardware button ─────────────────────────────────────────────────
      case "press_button": {
        const { button } = args as { button: string };
        sim("io", udid, "button", button);
        await new Promise((r) => setTimeout(r, 500));
        return { content: [{ type: "text", text: `Pressed ${button}` }] };
      }

      // ── Launch ──────────────────────────────────────────────────────────
      case "launch_app": {
        const bundleId = (args as Record<string, string>)?.bundle_id ?? BUNDLE_ID;
        sim("launch", udid, bundleId);
        await new Promise((r) => setTimeout(r, 1500));
        return { content: [{ type: "text", text: `Launched ${bundleId}` }] };
      }

      // ── Terminate ───────────────────────────────────────────────────────
      case "terminate_app": {
        const bundleId = (args as Record<string, string>)?.bundle_id ?? BUNDLE_ID;
        try { sim("terminate", udid, bundleId); } catch {}
        await new Promise((r) => setTimeout(r, 500));
        return { content: [{ type: "text", text: `Terminated ${bundleId}` }] };
      }

      // ── Deep link ───────────────────────────────────────────────────────
      case "open_deep_link": {
        const { url } = args as { url: string };
        sim("openurl", udid, url);
        await new Promise((r) => setTimeout(r, 800));
        return { content: [{ type: "text", text: `Opened ${url}` }] };
      }

      // ── List simulators ─────────────────────────────────────────────────
      case "list_simulators": {
        const raw = sim("list", "devices", "--json");
        const data = JSON.parse(raw) as {
          devices: Record<string, Array<{ name: string; udid: string; state: string; isAvailable: boolean }>>;
        };
        const lines: string[] = [];
        for (const [runtime, devices] of Object.entries(data.devices)) {
          const runtimeName = runtime.replace("com.apple.CoreSimulator.SimRuntime.", "").replace(/-/g, " ");
          const available = devices.filter((d) => d.isAvailable);
          if (available.length === 0) continue;
          lines.push(`\n**${runtimeName}**`);
          for (const d of available) {
            const state = d.state === "Booted" ? " [BOOTED ✓]" : "";
            lines.push(`  ${d.name}${state}\n  ${d.udid}`);
          }
        }
        return { content: [{ type: "text", text: lines.join("\n") }] };
      }

      // ── Console logs ────────────────────────────────────────────────────
      case "get_console_logs": {
        const lines = ((args as Record<string, number>)?.lines) ?? 60;
        let output = "";
        try {
          output = execSync(
            `xcrun simctl spawn ${udid} log show --predicate 'process == "ApexSightNative" OR process == "ApexSight"' --last 2m --style compact 2>/dev/null | tail -${lines}`,
            { encoding: "utf8" }
          );
        } catch {
          output = "(no logs available — ensure the app is running)";
        }
        return { content: [{ type: "text", text: output || "(no recent log output)" }] };
      }

      // ── Add finding ─────────────────────────────────────────────────────
      case "add_finding": {
        const { screen, status, description } = args as Finding;
        const finding: Finding = {
          screen,
          status,
          description,
          timestamp: new Date().toISOString(),
        };
        findings.push(finding);
        const icon = status === "pass" ? "✅" : status === "fail" ? "❌" : "⚠️";
        return {
          content: [{
            type: "text",
            text: `${icon} Recorded [${status.toUpperCase()}] for "${screen}"\nTotal findings: ${findings.length}`,
          }],
        };
      }

      // ── Generate report ─────────────────────────────────────────────────
      case "generate_report": {
        const { output_path, summary } = args as { output_path?: string; summary?: string };

        const pass = findings.filter((f) => f.status === "pass").length;
        const fail = findings.filter((f) => f.status === "fail").length;
        const warn = findings.filter((f) => f.status === "warn").length;
        const overall = fail === 0 ? "✅ PASS" : "❌ FAIL";
        const date = new Date().toLocaleDateString("en-US", {
          year: "numeric", month: "long", day: "numeric",
          hour: "2-digit", minute: "2-digit",
        });

        const sections: string[] = [
          `# ApexSight UI Test Report`,
          ``,
          `**Date:** ${date}  `,
          `**Overall:** ${overall}  `,
          `**Results:** ${pass} passed · ${fail} failed · ${warn} warnings`,
          ``,
        ];

        if (summary) {
          sections.push(`## Summary`, ``, summary, ``);
        }

        sections.push(`## Test Findings`, ``);

        const byScreen = new Map<string, Finding[]>();
        for (const f of findings) {
          const group = byScreen.get(f.screen) ?? [];
          group.push(f);
          byScreen.set(f.screen, group);
        }

        for (const [screen, screenFindings] of byScreen) {
          const worstStatus = screenFindings.some((f) => f.status === "fail")
            ? "❌"
            : screenFindings.some((f) => f.status === "warn")
            ? "⚠️"
            : "✅";
          sections.push(`### ${worstStatus} ${screen}`, ``);
          for (const f of screenFindings) {
            const icon = f.status === "pass" ? "✅" : f.status === "fail" ? "❌" : "⚠️";
            sections.push(`- ${icon} **[${f.status.toUpperCase()}]** ${f.description}`);
          }
          sections.push(``);
        }

        if (fail > 0) {
          sections.push(`## Issues to Fix`, ``);
          for (const f of findings.filter((f) => f.status === "fail")) {
            sections.push(`- [ ] **${f.screen}:** ${f.description}`);
          }
          sections.push(``);
        }

        if (warn > 0) {
          sections.push(`## UX Warnings`, ``);
          for (const f of findings.filter((f) => f.status === "warn")) {
            sections.push(`- **${f.screen}:** ${f.description}`);
          }
          sections.push(``);
        }

        const report = sections.join("\n");

        const defaultPath = path.join(os.homedir(), "Desktop", "apexsight-test-report.md");
        const savePath = output_path ?? defaultPath;
        const expanded = savePath.startsWith("~/")
          ? path.join(os.homedir(), savePath.slice(2))
          : savePath;

        fs.writeFileSync(expanded, report, "utf8");

        return {
          content: [{
            type: "text",
            text: `Report saved to: ${expanded}\n\n${report}`,
          }],
        };
      }

      // ── Clear findings ──────────────────────────────────────────────────
      case "clear_findings": {
        const count = findings.length;
        findings.length = 0;
        return { content: [{ type: "text", text: `Cleared ${count} findings. Ready for a fresh test run.` }] };
      }

      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    return { content: [{ type: "text", text: `Error: ${msg}` }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("ApexSight iOS Tester MCP server ready");
