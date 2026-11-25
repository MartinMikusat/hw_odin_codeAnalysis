import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const TOOL = join(homedir(), ".local/bin/hw-odin-analyze");
const BLOCK_EXIT_CODE = 2;

function blockReason(payload: object): Promise<string | undefined> {
  return new Promise((resolve) => {
    try {
      const child = spawn(TOOL, ["guard"], { stdio: ["pipe", "ignore", "pipe"], timeout: 10_000 });
      let message = "";
      child.stderr?.on("data", (chunk) => {
        message += chunk;
      });
      child.stdin?.on("error", () => {});
      child.on("error", () => resolve(undefined));
      child.on("close", (code) => resolve(code === BLOCK_EXIT_CODE ? message.trim() : undefined));
      child.stdin?.end(JSON.stringify(payload));
    } catch {
      resolve(undefined);
    }
  });
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return;
    const { command } = event.input as { command?: unknown };
    if (typeof command !== "string") return;
    const reason = await blockReason({
      agent: "pi",
      session_id: ctx.sessionManager.getSessionId(),
      cwd: ctx.cwd,
      tool_input: { command },
    });
    if (reason) return { block: true, reason };
  });
}
