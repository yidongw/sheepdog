// The review prompt reaches codex through stdin, never argv (tralyx dev 9ef7d5d06, 2026-11-14: a ~39-commit dev range
// plus the prior round's findings passed Linux's 128 KiB MAX_ARG_STRLEN, "reviewer failed: spawn E2BIG", no review).
// A fake docker runs the real container command line (`sh -c '<relay> & …; exec "$0" "$@"'`) with the relay swapped
// for a stdin-reading `cat` (proving the sidecar cannot eat the prompt) and codex swapped for a hasher.
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, expect, it } from "vitest";
import { assertSmallArgv, buildReviewPrompt, runHeadlessReviewer, runReviewerProcess, type PriorRound } from "../src/reviewer.ts";

let root: string;
let saved: NodeJS.ProcessEnv;
beforeEach(() => { root = mkdtempSync(path.join(tmpdir(), "sheepdog-stdin-")); saved = { ...process.env }; });
afterEach(() => { process.env = saved; rmSync(root, { recursive: true, force: true }); });

const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");

function setup(): void {
  const packageRoot = path.join(root, "codex");
  const native = path.join(packageRoot, `node_modules/@openai/codex-linux-${process.arch}/vendor/${process.arch === "arm64" ? "aarch64" : "x86_64"}-unknown-linux-musl/bin/codex`);
  mkdirSync(path.dirname(native), { recursive: true });
  writeFileSync(native, "");
  const home = path.join(root, "home");
  mkdirSync(home);
  writeFileSync(path.join(home, "config.toml"), 'model_provider = "p"\n[model_providers.p]\nbase_url = "http://127.0.0.1:3425/v1"\n');
  const hasher = path.join(root, "hasher.cjs");
  writeFileSync(hasher, `#!${process.execPath}
const chunks = [];
process.stdin.on("data", (c) => chunks.push(c));
process.stdin.on("end", () => {
  const b = Buffer.concat(chunks);
  const maxArg = Math.max(...process.argv.slice(2).map((a) => Buffer.byteLength(a)));
  console.log(JSON.stringify({ bytes: b.length, sha: require("node:crypto").createHash("sha256").update(b).digest("hex"), last: process.argv.at(-1), maxArg }));
});
`, { mode: 0o755 });
  const docker = path.join(root, "docker.cjs");
  writeFileSync(docker, `#!${process.execPath}
const args = process.argv.slice(2);
if (args[0] === "rm") process.exit(0);
const fs = require("node:fs");
fs.writeFileSync(${JSON.stringify(path.join(root, "docker-argv.json"))}, JSON.stringify({ args, maxArg: Math.max(...args.map((a) => Buffer.byteLength(a))) }));
const at = args.indexOf("--entrypoint");
const [entry, , dashC, script, , ...rest] = args.slice(at + 1);
const sidecar = script.replace(/^socat \\S+ \\S+/, "cat >/dev/null");
if (sidecar === script || !args.includes("-i")) process.exit(9);
const r = require("node:child_process").spawnSync(entry, [dashC, sidecar, ${JSON.stringify(hasher)}, ...rest], { stdio: "inherit" });
process.exit(r.status ?? 1);
`, { mode: 0o755 });
  Object.assign(process.env, {
    CODEREVIEW_BACKEND: "codex",
    CODEREVIEW_CODEX_HOME: home,
    CODEREVIEW_CODEX_PACKAGE_ROOT: packageRoot,
    CODEREVIEW_DOCKER_BIN: docker,
  });
}

it.skipIf(process.platform !== "linux").each([200 * 1024, 1024 * 1024])("a %i-byte prior round reaches the containerised reviewer intact on stdin; argv stays small", async (size) => {
  setup();
  const head = "a".repeat(40);
  const base = "b".repeat(40);
  const prior: PriorRound = { fixOf: ["c".repeat(40)], disputes: [], reviewed: [], findings: `the review that blocked ${"c".repeat(40)} \n${"BLOCKED #1 x — ü\n".repeat(size / 18)}` };
  const prompt = buildReviewPrompt(head, base, prior);
  expect(Buffer.byteLength(prompt)).toBeGreaterThan(size); // past MAX_ARG_STRLEN
  const r = await runHeadlessReviewer(head, process.cwd(), 30_000, base, { prior });
  expect(r.error).toBe(null);
  const out = JSON.parse(r.stdout.trim().split("\n").at(-1)!);
  expect(out.bytes).toBe(Buffer.byteLength(prompt));
  expect(out.sha).toBe(sha256(prompt));
  expect(out.last).toBe("-");
  expect(out.maxArg).toBeLessThan(4096);
  const { readFileSync } = await import("node:fs");
  const docker = JSON.parse(readFileSync(path.join(root, "docker-argv.json"), "utf8"));
  expect(docker.maxArg).toBeLessThan(4096);
  expect(docker.args.join("\n")).not.toContain("BLOCKED #1");
});

it("runReviewerProcess: input goes to stdin and is closed; a reviewer that ignores stdin is no error", async () => {
  const cat = path.join(root, "cat.cjs");
  writeFileSync(cat, `#!${process.execPath}\nlet n = 0; process.stdin.on("data", (c) => n += c.length); process.stdin.on("end", () => console.log(n));\n`, { mode: 0o755 });
  const input = "x".repeat(3 * 1024 * 1024);
  const r = await runReviewerProcess(cat, [], root, process.env, 10_000, "codex", () => {}, input);
  expect(r.error).toBe(null);
  expect(r.stdout.trim()).toBe(String(input.length));
  const quick = path.join(root, "quick.cjs");
  writeFileSync(quick, `#!${process.execPath}\nconsole.log("done");\n`, { mode: 0o755 });
  const q = await runReviewerProcess(quick, [], root, process.env, 10_000, "codex", () => {}, input);
  expect(q.error).toBe(null);
  expect(q.stdout.trim()).toBe("done");
  // no input: stdin is /dev/null (immediate EOF), as before
  const n = await runReviewerProcess(cat, [], root, process.env, 10_000, "codex");
  expect(n.stdout.trim()).toBe("0");
});

it("assertSmallArgv refuses data in argv", () => {
  expect(() => assertSmallArgv(["exec", "-"])).not.toThrow();
  expect(() => assertSmallArgv(["exec", "p".repeat(200 * 1024)])).toThrow(/argv/);
});
