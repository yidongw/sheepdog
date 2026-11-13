// review-gate end to end with a fake docker (the container command is recorded, a verdict printed): exit codes, the
// isolation arguments it really passes, and the BLOCKED lines the dispatcher reads.
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, it } from "vitest";

const gate = path.join(import.meta.dirname, "../src/review-gate.ts");

function fixture(verdictLine: string) {
  const root = mkdtempSync(path.join(tmpdir(), "sheepdog-gate-"));
  const repo = path.join(root, "repo");
  mkdirSync(repo);
  const g = (...a: string[]) => execFileSync("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", ...a], { encoding: "utf8" }).trim();
  g("init", "-q");
  writeFileSync(path.join(repo, "a.txt"), "1\n"); g("add", "."); g("commit", "-qm", "base");
  const base = g("rev-parse", "HEAD");
  writeFileSync(path.join(repo, "a.txt"), "2\n"); g("commit", "-qam", "change");
  const head = g("rev-parse", "HEAD");
  const pkg = path.join(root, "codex");
  const native = path.join(pkg, process.arch === "arm64"
    ? "node_modules/@openai/codex-linux-arm64/vendor/aarch64-unknown-linux-musl/bin/codex"
    : "node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex");
  mkdirSync(path.dirname(native), { recursive: true }); writeFileSync(native, "");
  const home = path.join(root, "codex-home"); mkdirSync(home);
  writeFileSync(path.join(home, "config.toml"), 'model_provider = "p"\n[model_providers.p]\nbase_url = "http://127.0.0.1:9/v1"\nexperimental_bearer_token = "secret-bearer"\n');
  const docker = path.join(root, "docker");
  writeFileSync(docker, `#!/bin/sh\n[ "$1" = rm ] && exit 0\nprintf '%s\\n' "$@" > ${JSON.stringify(path.join(root, "argv"))}\nprintf '%s\\n' ${JSON.stringify(verdictLine)}\n`, { mode: 0o755 });
  const envFile = path.join(root, "review.env");
  writeFileSync(envFile, `CODEREVIEW_CODEX_HOME=${home}\nCODEREVIEW_BACKEND=codex\n`);
  const run = (extra: string[] = []) => spawnSync(process.execPath, [gate, "--base", base, "--head", head, ...extra], {
    cwd: repo, encoding: "utf8",
    env: { PATH: process.env.PATH, SHEEPDOG_ENV_FILE: envFile, CODEREVIEW_DOCKER_BIN: docker, CODEREVIEW_CODEX_PACKAGE_ROOT: pkg },
  });
  return { root, run };
}

it.skipIf(process.platform !== "linux")("clean verdict → exit 0, in the isolated container", () => {
  const f = fixture('VERDICT: {"verdict":"clean","finding":"","evidence":"read a.txt"}');
  const r = f.run();
  expect(r.status).toBe(0);
  const argv = readFileSync(path.join(f.root, "argv"), "utf8").split("\n");
  expect(argv[argv.indexOf("--network") + 1]).toBe("none");
  expect(argv.join(" ")).not.toContain("secret-bearer"); // the token stays with the host relay
  expect(argv).toContain("project_doc_max_bytes=0");
});

it.skipIf(process.platform !== "linux")("blocking verdict → exit 1 with ROUTE / FINDING / BLOCKED / evidence lines", () => {
  const f = fixture('VERDICT: {"verdict":"regression","finding":"breaks a","evidence":"a.txt:1","severity":"blocker","route":"fixer"}');
  const r = f.run();
  expect(r.status).toBe(1);
  expect(r.stderr).toMatch(/^review-gate: ROUTE fixer/m);
  expect(r.stderr).toMatch(/^review-gate: BLOCKED #1 regression \[blocker\]: breaks a$/m);
  expect(r.stderr).toMatch(/^evidence: a\.txt:1$/m);
});

it.skipIf(process.platform !== "linux")("no parseable verdict → exit 2 (not a pass)", () => {
  expect(fixture("the model rambled").run().status).toBe(2);
});
