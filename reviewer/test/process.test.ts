// The reviewer process wrapper: its whole process group is stopped on timeout and on a signal to the parent; stdout is
// drained; a nonzero exit is an error even with a verdict on stdout.
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { runReviewerProcess } from "../src/reviewer.ts";

let dir: string;
beforeEach(() => { dir = mkdtempSync(path.join(tmpdir(), "sheepdog-proc-")); });
afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

function fake(script: string): string {
  const bin = path.join(dir, "reviewer.cjs");
  writeFileSync(bin, `#!${process.execPath}\n${script}`, { mode: 0o755 });
  return bin;
}
const gone = (pid: number) => {
  let state = "";
  try { state = execFileSync("ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).trim(); } catch { /* reaped */ }
  return state === "" || state.startsWith("Z");
};

it.skipIf(process.platform === "win32")("stops descendant tools before returning a timeout", async () => {
  const tool = "console.log(process.pid); setTimeout(() => {}, 10000);";
  const native = `require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(tool)}], { stdio: 'inherit' });`;
  const bin = fake(`
    const child = require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(native)}], { stdio: 'inherit' });
    process.on('SIGTERM', () => child.kill('SIGTERM'));
    child.on('exit', () => process.exit());
  `);
  let cleaned = 0;
  const result = await runReviewerProcess(bin, [], dir, process.env, 2000, "codex", () => { cleaned++; });
  const toolPid = Number(result.stdout.trim());
  try {
    expect(result.timedOut).toBe(true);
    expect(result.error).toMatch(/timed out/);
    expect(toolPid).toBeGreaterThan(0);
    expect(gone(toolPid)).toBe(true);
    expect(cleaned).toBeGreaterThan(0); // the container cleanup ran
  } finally {
    if (toolPid > 0) { try { process.kill(toolPid, "SIGKILL"); } catch { /* gone */ } }
  }
});

it.skipIf(process.platform === "win32").each(["SIGINT", "SIGTERM"] as const)("stops the reviewer and its tools when the parent receives %s", async (signal) => {
  const reviewerPidFile = path.join(dir, "reviewer.pid");
  const toolPidFile = path.join(dir, "tool.pid");
  const tool = `require('node:fs').writeFileSync(${JSON.stringify(toolPidFile)}, String(process.pid)); setTimeout(() => {}, 10000);`;
  const bin = fake(`
    require('node:fs').writeFileSync(${JSON.stringify(reviewerPidFile)}, String(process.pid));
    require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(tool)}], { stdio: 'inherit' });
  `);
  const fixture = path.join(dir, "parent.mts");
  const mod = pathToFileURL(path.join(import.meta.dirname, "../src/reviewer.ts")).href;
  writeFileSync(fixture, `
    import { runReviewerProcess } from ${JSON.stringify(mod)};
    await runReviewerProcess(${JSON.stringify(bin)}, [], process.cwd(), process.env, 8000, "codex");
  `);
  const parent = spawn(process.execPath, [fixture], { stdio: "ignore", timeout: 10000, killSignal: "SIGKILL" });
  const exited = once(parent, "exit");
  try {
    await vi.waitFor(() => expect(existsSync(toolPidFile)).toBe(true), { timeout: 5000 });
    const pids = [reviewerPidFile, toolPidFile].map((f) => Number(readFileSync(f, "utf8")));
    expect(parent.kill(signal)).toBe(true);
    expect(await exited).toEqual([null, signal]);
    await vi.waitFor(() => { for (const pid of pids) expect(gone(pid)).toBe(true); }, { timeout: 1000 });
  } finally {
    parent.kill("SIGKILL");
    for (const f of [toolPidFile, reviewerPidFile]) {
      if (!existsSync(f)) continue;
      try { process.kill(Number(readFileSync(f, "utf8")), "SIGKILL"); } catch { /* gone */ }
    }
    await exited;
  }
});

it.each([0, 2000])("returns final stdout with timeout=%i without treating progress as failure", async (timeoutMs) => {
  const bin = fake(`console.error('progress'); console.log('VERDICT: {"verdict":"clean"}');`);
  const result = await runReviewerProcess(bin, [], dir, process.env, timeoutMs, "codex");
  expect(result).toEqual({ stdout: 'VERDICT: {"verdict":"clean"}\n', error: null, timedOut: false });
});

it("reports a nonzero CLI exit even if stdout contains a verdict", async () => {
  const bin = fake(`console.log('VERDICT: {"verdict":"clean"}'); console.error('provider failed'); process.exitCode = 1;`);
  const result = await runReviewerProcess(bin, [], dir, process.env, 2000, "codex");
  expect(result.error).toBe("provider failed");
  expect(result.timedOut).toBe(false);
});

it("reports spawn failures without throwing", async () => {
  const result = await runReviewerProcess(path.join(dir, "missing"), [], dir, process.env, 2000, "codex");
  expect(result.error).toContain("ENOENT");
  expect(result.timedOut).toBe(false);
});
