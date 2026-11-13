/**
 * review-gate — the blocking code review step of sheepdog's review workflow: review base..head with the isolated
 * reviewer (reviewer.ts) and turn the verdict into an exit code.
 *
 *   node reviewer/src/review-gate.ts --base <sha> --head <sha> [--prior <file>] [--known-open <file>]
 *        [--pin-repo <owner/name> --pin-from <sha> --pin-to <sha> --pin-diff <file> --pin-log <file>]
 *
 * --pin-*: the range moves the caller's sheepdog pin; the sheepdog diff from..to (prepared by review.yml from sheepdog's
 * history) is reviewed with the range.
 *
 * Exit codes: 0 clean · 1 the reviewer found a blocking problem (ducktape / missed-class / regression) · 2 no verdict
 * (the reviewer failed, timed out, or printed nothing parseable). 2 is deliberately a failure too: a review that did not
 * happen is not a pass.
 *
 * It writes nothing and wakes nobody itself: the dispatcher (scripts/ci/review-dispatch.sh) reads this step's log after
 * the run completes — `review-gate: ROUTE / FINDING #n / BLOCKED #n / evidence:` lines on stderr, NOTE / NIT lines on
 * stdout. The checkout in the current directory must be at <head> with <base> reachable.
 * Settings: the CODEREVIEW_* environment, optionally loaded from SHEEPDOG_ENV_FILE (reviewer.ts).
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

import { loadEnvFile } from "./env-file.ts";
import { buildPinBumpBlock, gateBlockedLines, isGatewayLoopStop, parseVerdict, priorRoundFromLog, runHeadlessReviewer } from "./reviewer.ts";
import type { PinBump, ReviewFinding } from "./reviewer.ts";

function flag(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const git = (...args: string[]) => execFileSync("git", args, { encoding: "utf8" }).trim();

const tag = (f: ReviewFinding) => `[${f.severity}${f.risk ? `, ${f.risk}` : ""}]`;

async function main(): Promise<number> {
  loadEnvFile(process.env.SHEEPDOG_ENV_FILE || undefined);
  const baseArg = flag("base");
  const headArg = flag("head");
  if (!baseArg || !headArg) {
    console.error("usage: review-gate --base <sha> --head <sha>");
    return 2;
  }
  const head = git("rev-parse", `${headArg}^{commit}`);
  const base = git("rev-parse", `${baseArg}^{commit}`);
  if (git("rev-parse", "HEAD") !== head) {
    console.error(`review-gate: HEAD is not ${head.slice(0, 8)}; check out the reviewed commit first`);
    return 2;
  }
  if (base === head) {
    console.log("review-gate: empty range, nothing to review");
    return 0;
  }
  const timeoutMs = Number(process.env.CODEREVIEW_TIMEOUT_MS ?? 30 * 60_000);

  console.log(`review-gate: reviewing ${base.slice(0, 8)}..${head.slice(0, 8)}`);
  // The review ledger (owner 11-12): --prior <file> = previous findings fetched by scripts/ci/prior-findings.sh.
  const priorFile = flag("prior");
  const prior = priorRoundFromLog(
    git("log", "--format=%H%x00%B%x1e", `${base}..${head}`),
    priorFile && existsSync(priorFile) ? readFileSync(priorFile, "utf8") : "",
  );
  if (prior.fixOf.length) {
    console.log(`review-gate: prior round — fixes of ${prior.fixOf.map((x) => x.slice(0, 9)).join(", ")}, ${prior.disputes.length} dispute(s), previous findings ${prior.findings.trim() ? "attached" : "unavailable"}`);
  }
  // Known open findings (owner 11-13): repeats of findings past their fix rounds are pre-existing, not blocking again.
  const knownOpenFile = flag("known-open");
  if (knownOpenFile && existsSync(knownOpenFile)) {
    const known = readFileSync(knownOpenFile, "utf8").trim();
    if (known) { prior.knownOpen = known; console.log(`review-gate: ${known.split("\n").length} known open finding(s) attached`); }
  }
  let pin: PinBump | undefined;
  const pinFlags = ["pin-repo", "pin-from", "pin-to", "pin-diff", "pin-log"];
  if (pinFlags.some((f) => process.argv.includes(`--${f}`))) {
    // All or nothing, each one valid (review of 0f5d80c10 #5): a partial set must not drop the sheepdog diff silently.
    pin = { repo: flag("pin-repo") ?? "", from: flag("pin-from") ?? "", to: flag("pin-to") ?? "", diffFile: flag("pin-diff") ?? "", logFile: flag("pin-log") ?? "" };
    if (!buildPinBumpBlock(pin) || !existsSync(pin.diffFile) || !existsSync(pin.logFile)) {
      console.error("review-gate: --pin-* given but incomplete or invalid (owner/name repo, 40-hex from and to, existing diff and log files)");
      return 2;
    }
    console.log(`review-gate: sheepdog pin bump ${pin.from.slice(0, 9)}..${pin.to.slice(0, 9)} — its diff is reviewed with the range`);
  }
  let run = await runHeadlessReviewer(head, process.cwd(), timeoutMs, base, { prior, pin });
  // A model gateway's loop guard can end a turn after repeated identical tool results; that is not a verdict. One
  // fresh attempt.
  if (!run.error && !parseVerdict(run.stdout) && isGatewayLoopStop(run.stdout)) {
    console.error("review-gate: gateway stopped a polling loop, one fresh attempt");
    run = await runHeadlessReviewer(head, process.cwd(), timeoutMs, base, { prior, pin });
  }
  if (run.error) {
    console.error(`review-gate: reviewer ${run.timedOut ? "timed out" : "failed"}: ${run.error}`);
    console.error(run.stdout.trim().slice(-800));
    return 2;
  }
  const v = parseVerdict(run.stdout);
  if (!v) {
    console.error("review-gate: no parseable VERDICT line (not a pass). Reviewer output tail:");
    console.error(run.stdout.trim().slice(-1500));
    return 2;
  }
  // "#n" numbers the blocking findings: a fixer's `Review-Disputed: <finding #> …` trailer refers to it.
  // review-dispatch.sh reads `review-gate: BLOCKED` / `evidence:` lines as findings; NIT lines go only to its notes.
  const top = v.findings[0];
  const summary = `${v.verdict}${top ? ` ${tag(top)}` : ""}: ${v.finding}${v.evidence ? `\nevidence: ${v.evidence}` : ""}` +
    v.findings.slice(1).map((f, i) => `\nreview-gate: BLOCKED #${i + 2} ${f.verdict} ${tag(f)}: ${f.finding}${f.evidence ? `\nevidence: ${f.evidence}` : ""}`).join("");
  // Advisory notes and nits never change the exit code; review-dispatch.sh relays them as non-blocking notes.
  if (v.notes) console.log(`review-gate: NOTE (non-blocking): ${v.notes.replace(/\s+/g, " ")}`);
  for (const n of v.nits) {
    console.log(`review-gate: NIT (non-blocking): ${n.verdict}: ${n.finding.replace(/\s+/g, " ")}${n.evidence ? ` (${n.evidence.replace(/\s+/g, " ")})` : ""}`);
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    const { appendFileSync } = await import("node:fs");
    appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      `### Code review ${base.slice(0, 8)}..${head.slice(0, 8)}: **${v.verdict}**\n\n${v.finding}\n\n${v.evidence ? `Evidence: ${v.evidence}\n` : ""}${v.notes ? `\nNote (non-blocking): ${v.notes}\n` : ""}`,
    );
  }
  if (v.verdict === "clean") {
    console.log(`review-gate: ${summary}`);
    return 0;
  }
  // Routing (owner 11-12): who fixes each blocking finding and the culprit commit the reviewer named ("-" = none),
  // each FINDING line next to its own BLOCKED / evidence lines (re-check of 32e2af473 #6).
  for (const line of gateBlockedLines(v)) console.error(line);
  return 1;
}

main().then(
  (code) => process.exit(code),
  (err: unknown) => {
    console.error("review-gate: crashed:", err);
    process.exit(2);
  },
);
