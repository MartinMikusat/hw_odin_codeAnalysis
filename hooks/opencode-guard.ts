import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve as resolvePath } from "node:path";

const TOOL = join(homedir(), ".local/bin/hw-odin-analyze");
const BLOCK_EXIT_CODE = 2;

type ShellCall = {
  tool: string;
  sessionID: string;
  input: unknown;
};

type Context = {
  location: { directory: string };
  tool: {
    hook(name: "execute.before", callback: (event: ShellCall) => Promise<void>): Promise<unknown>;
  };
};

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

export default {
  id: "hw-odin-guard",
  async setup(context: Context) {
    await context.tool.hook("execute.before", async (event) => {
      if (event.tool !== "shell") return;
      const { command, workdir } = (event.input ?? {}) as { command?: unknown; workdir?: unknown };
      if (typeof command !== "string") return;
      const reason = await blockReason({
        agent: "opencode",
        session_id: event.sessionID,
        cwd: resolvePath(context.location.directory, typeof workdir === "string" ? workdir : "."),
        tool_input: { command },
      });
      if (reason) throw new Error(reason);
    });
  },
};
