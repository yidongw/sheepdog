// review-gate end to end with a fake docker (the container command is recorded, a verdict printed): exit codes, the
// isolation arguments it really passes, and the BLOCKED lines the dispatcher reads.
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, it } from "vitest";

const gate = path.join(import.meta.dirname, "../src/review-gate.ts");

function fixture(verdict: string | ((c: { base: string; head: string }) => string)) {
  const root = mkdtempSync(path.join(tmpdir(), "sheepdog-gate-"));
  const repo = path.join(root, "repo");
  mkdirSync(repo);
  const g = (...a: string[]) => execFileSync("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", ...a], { encoding: "utf8" }).trim();
  g("init", "-q");
  writeFileSync(path.join(repo, "a.txt"), "1\n"); g("add", "."); g("commit", "-qm", "base");
  const base = g("rev-parse", "HEAD");
  writeFileSync(path.join(repo, "a.txt"), "2\n"); g("commit", "-qam", "change");
  const head = g("rev-parse", "HEAD");
  const verdictLine = typeof verdict === "string" ? verdict : verdict({ base, head });
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
  return { root, run, base, head };
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

// review of 0f5d80c10 #5: a partial or invalid --pin-* set fails (exit 2) instead of silently reviewing without the
// sheepdog diff; a complete one reaches the container (both files bound read-only).
it.skipIf(process.platform !== "linux")("pin bump arguments: all or nothing, each valid", () => {
  const f = fixture('VERDICT: {"verdict":"clean","finding":"","evidence":"read a.txt"}');
  const diff = path.join(f.root, "pin.diff"); const log = path.join(f.root, "pin.log");
  writeFileSync(diff, "d"); writeFileSync(log, "l");
  const full = ["--pin-repo", "yidongw/sheepdog", "--pin-from", "a".repeat(40), "--pin-to", "b".repeat(40), "--pin-diff", diff, "--pin-log", log];
  const without = (flag: string) => { const i = full.indexOf(flag); return [...full.slice(0, i), ...full.slice(i + 2)]; };
  for (const flag of ["--pin-repo", "--pin-from", "--pin-to", "--pin-diff", "--pin-log"]) expect(f.run(without(flag)).status).toBe(2);
  expect(f.run(full.map((x) => (x === "yidongw/sheepdog" ? "" : x))).status).toBe(2);
  expect(f.run(full.map((x) => (x === "b".repeat(40) ? "main" : x))).status).toBe(2);
  expect(f.run(full.map((x) => (x === log ? path.join(f.root, "missing") : x))).status).toBe(2);
  const r = f.run(full);
  expect(r.status).toBe(0);
  const argv = readFileSync(path.join(f.root, "argv"), "utf8").split("\n");
  expect(argv).toContain(`${diff}:${diff}:ro`);
  expect(argv).toContain(`${log}:${log}:ro`);
});

// The default-branch rule of a DEV review (--dev-main <the default branch's sha>): a blocking finding whose culprit commit
// (full sha) is already on the default branch is a [pre-existing] note — the gate converts it whatever the reviewer said
// (exit 0 when nothing else blocks). A culprit off the default branch, "-", or an abbreviated sha keeps blocking; without
// --dev-main (a re-check of the default branch) the same finding blocks.
const finding = (commit: string, text: string) =>
  ({ verdict: "regression", finding: text, evidence: "a.txt:1", severity: "should", route: "fixer", commit, preexisting: false });
const verdictOf = (...fs: ReturnType<typeof finding>[]) =>
  `VERDICT: ${JSON.stringify({ ...fs[0], findings: fs })}`;

it.skipIf(process.platform !== "linux")("dev review: a culprit on the default branch is a pre-existing note, not a block", () => {
  const f = fixture(({ base }) => verdictOf(finding(base, "main's own bug")));
  const r = f.run(["--dev-main", f.base]);
  expect(r.status).toBe(0);
  expect(r.stdout).toMatch(/^review-gate: NIT \(non-blocking\): regression: \[pre-existing\] main's own bug/m);
  expect(r.stdout).toContain(`review-gate: culprit ${f.base.slice(0, 12)} is on the default branch`);
  expect(r.stderr).not.toMatch(/BLOCKED/);
  // a re-check (no --dev-main): the same verdict blocks
  const recheck = f.run();
  expect(recheck.status).toBe(1);
  expect(recheck.stderr).toMatch(new RegExp(`^review-gate: FINDING #1 route=fixer commit=${f.base}$`, "m"));
  expect(recheck.stderr).toMatch(/^review-gate: BLOCKED #1 regression \[should\]: main's own bug$/m);
});

it.skipIf(process.platform !== "linux")("dev review, mixed: only the range's own finding blocks", () => {
  const f = fixture(({ base, head }) => verdictOf(finding(base, "main's own bug"), finding(head, "the range's bug")));
  const r = f.run(["--dev-main", f.base]);
  expect(r.status).toBe(1);
  expect(r.stderr).toMatch(new RegExp(`^review-gate: FINDING #1 route=fixer commit=${f.head}$`, "m"));
  expect(r.stderr).toMatch(/^review-gate: BLOCKED #1 regression \[should\]: the range's bug$/m);
  expect(r.stderr).not.toMatch(/main's own bug/);
  expect(r.stderr).not.toMatch(/BLOCKED #2/);
  expect(r.stdout).toMatch(/\[pre-existing\] main's own bug/);
});

it.skipIf(process.platform !== "linux")("dev review: no culprit, '-', an abbreviated sha or a commit off the default branch keeps blocking", () => {
  const cases: ((c: { base: string; head: string }) => string)[] = [() => "", () => "-", (c) => c.base.slice(0, 12), (c) => c.head, () => "f".repeat(40)];
  for (const pick of cases) {
    const f = fixture((c) => verdictOf(finding(pick(c), "a bug")));
    const r = f.run(["--dev-main", f.base]);
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/^review-gate: BLOCKED #1 regression \[should\]: a bug$/m);
  }
});

it.skipIf(process.platform !== "linux")("--dev-main must be the full sha of a commit", () => {
  const f = fixture('VERDICT: {"verdict":"clean","finding":"","evidence":"read a.txt"}');
  expect(f.run(["--dev-main", f.base.slice(0, 12)]).status).toBe(2);
  expect(f.run(["--dev-main", "e".repeat(40)]).status).toBe(2);
  expect(f.run(["--dev-main"]).status).toBe(2);
  expect(f.run(["--dev-main", f.base]).status).toBe(0);
});
