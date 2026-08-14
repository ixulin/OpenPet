#!/usr/bin/env node
// OpenPet bridge for Claude Code hooks — Node.js fast path.
// Replaces the PowerShell version for latency: node cold-start is ~50-100ms
// vs powershell's 500ms-2s. Same event contract, same HTTP target.
//
// Two modes:
//   1) Hook mode (Claude Code calls this script): reads event JSON from stdin,
//      maps to OpenPet events, POSTs to the local runtime.
//   2) CLI mode (manual): openpet-hook.mjs --event <type> [--message "..."] [--ttl <ms>]
// Sends a companion event to the local OpenPet runtime (http://127.0.0.1:17321).
// Fast and silent: 2s HTTP timeout, swallows errors so it never blocks the session.

const argv = process.argv.slice(2);
const arg = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

// ── debug logging (OPENPET_HOOK_DEBUG=1) ──────────────────────────────
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
const dbg = (msg) => {
  if (process.env.OPENPET_HOOK_DEBUG !== "1") return;
  try {
    fs.appendFileSync(
      path.join(os.tmpdir(), "openpet-hook-debug.log"),
      `[${new Date().toISOString()}] ${msg}\n`,
    );
  } catch {
    // never let debug logging break the hook
  }
};

const truncate = (text, maxLen = 100) => {
  if (!text) return "";
  return text.length > maxLen ? text.slice(0, maxLen - 3) + "..." : text;
};

// Split-Path -Leaf equivalent: last non-empty path segment (handles / and \).
const pathLeaf = (p) => {
  if (!p) return null;
  return p.split(/[\\/]/).filter(Boolean).at(-1) || null;
};

async function sendEvent(type, message, ttlMs = 600000) {
  const host = process.env.CODEX_PET_RUNTIME_HOST || "127.0.0.1";
  const port = process.env.CODEX_PET_RUNTIME_PORT || "17321";
  const url = `http://${host}:${port}/api/event`;

  const body = { type };
  if (message) body.message = message;
  if (ttlMs > 0) body.ttlMs = ttlMs;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2000);
  try {
    await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8" },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch {
    // runtime unreachable — never block the session
  } finally {
    clearTimeout(timer);
  }
}

// ── CLI mode first (fast path, no stdin read) ─────────────────────────
// Process CLI params before touching stdin so empty pipes never block.

// const cliEvent = arg("--event");
// if (cliEvent) {
//   const message = arg("--message") || "";
//   const ttl = Number.parseInt(arg("--ttl") ?? "600000", 10);
//   await sendEvent(cliEvent, truncate(message, 120), ttl);
//   process.exit(0);
// }

// ── Hook mode (stdin): Claude Code pipes event JSON ───────────────────

let raw = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) raw += chunk;
dbg(`stdin len=${raw.length} content=${raw.slice(0, 300)}`);

if (!raw.trim()) {
  const ttl = Number.parseInt(arg("--ttl") ?? "600000", 10);
  await sendEvent("success", truncate("stdin为空！", 120), ttl);
  process.exit(0);
}

let data;
try {
  data = JSON.parse(raw);
} catch (e) {
  // Malformed input — bail silently.
  dbg(`JSON.parse FAILED: ${e.message}`);
  const ttl = Number.parseInt(arg("--ttl") ?? "600000", 10);
  await sendEvent("success", truncate("stdin为空！", 120), ttl);
  process.exit(0);
}

const event = data.hook_event_name;
let bubbleType = "thinking";
let bubbleText = "";
let ttl = 600000;

switch (event) {
  case "PreToolUse": {
    bubbleType = "tool-running";
    const tool = data.tool_name;
    const input = data.tool_input || {};

    switch (tool) {
      case "Bash": bubbleText = `执行命令: ${input.command || ""}`; break;
      case "Read": bubbleText = `读取文件: ${pathLeaf(input.file_path) || "..."}`; break;
      case "Write": bubbleText = `写入文件: ${pathLeaf(input.file_path) || "..."}`; break;
      case "Edit": bubbleText = `编辑文件: ${pathLeaf(input.file_path) || "..."}`; break;
      case "Glob": bubbleText = `搜索文件: ${input.pattern}`; break;
      case "Grep": bubbleText = `搜索内容: ${input.pattern}`; break;
      case "TaskCreate": bubbleText = `创建任务: ${input.subject}`; break;
      case "TaskUpdate": bubbleText = "更新任务状态"; break;
      case "WebFetch": bubbleText = `获取网页: ${input.url}`; break;
      case "WebSearch": bubbleText = `搜索网络: ${input.query}`; break;
      case "Agent": bubbleText = `启动子代理: ${input.description}`; break;
      case "EnterPlanMode": bubbleText = "进入规划模式..."; break;
      default: bubbleText = `调用工具: ${tool}`;
    }
    break;
  }

  case "PostToolUse": {
    const tool = data.tool_name;
    // Check for errors in tool_response (matches PS regex error|Error|failed|Failed)
    const resp = data.tool_response;
    if (typeof resp === "string" && /error|Error|failed|Failed/.test(resp)) {
      bubbleType = "failure";
      bubbleText = `${tool} 执行出错`;
    } else {
      bubbleType = "success";
      bubbleText = `${tool} 完成`;
      process.exit(0);
    }
    break;
  }

  case "Stop":
    bubbleType = "reviewing";
    bubbleText = "Claude 已完成本轮回复";
    break;

  case "UserPromptSubmit":
    bubbleType = "thinking";
    bubbleText = "收到输入，思考中...";
    break;

  case "Notification":
    bubbleType = "attention";
    bubbleText = data.message ? `通知：${data.message}` : "收到通知";
    break;

  case "PreCompact":
    bubbleType = "thinking";
    bubbleText = "正在压缩上下文...";
    break;

  case "SessionStart":
    bubbleType = "attention";
    bubbleText = "新会话开始";
    break;

  case "SessionEnd":
    bubbleType = "reviewing";
    bubbleText = "会话结束";
    break;

  case "PostToolUseFailure":
    bubbleType = "failure";
    bubbleText = data.tool_name ? `${data.tool_name} 执行失败` : "工具执行失败";
    break;

  case "StopFailure":
    bubbleType = "failure";
    bubbleText = "Claude 响应出错";
    break;

  case "SubagentStop":
    bubbleType = "success";
    bubbleText = "子代理完成";
    process.exit(0);
    break;

  case "TaskCompleted":
    bubbleType = "success";
    bubbleText = "后台任务完成";
    break;

  default:
    bubbleText = `事件: ${event}`;
}

// 先截断主体，再追加工作目录末级目录名，保证目录始终显示
bubbleText = truncate(bubbleText, 100);

const cwdLeaf = pathLeaf(data.cwd);
if (cwdLeaf && bubbleText) {
  bubbleText = `[${cwdLeaf}] ${bubbleText}`;
}

dbg(`event=${event} -> type=${bubbleType} text=${bubbleText} ttl=${ttl}`);
await sendEvent(bubbleType, bubbleText, ttl);
process.exit(0);
