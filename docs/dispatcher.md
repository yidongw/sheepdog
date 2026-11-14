# The dispatcher

`scripts/ci/review-dispatch.sh` acts on finished reviews for ONE repository. A host runs it every minute (a systemd
timer or cron) through a small wrapper that refreshes a trusted checkout of sheepdog's main and passes the repository's
settings. It never prints secrets; `touch $STATE/PAUSED` stops it; `DRY=1` logs what it would do.

## What it does

- **Merge train**: fast-forwards the default branch to the newest dev head whose trusted tests and review passed
  (`review-passed.sh`), or merges it as a `Train-Merge:` commit when the default branch moved (a hotfix).
- **Hotfixes back into dev**: a direct commit on the default branch is merged into dev (a merge, never a rebase).
- **Blocked reviews**: reviewer → fixer → author. The reviewer routes each finding; a fixer agent (a T3 thread) gets
  the `fixer` findings and pushes `devfix/<sha>`; findings routed to the author wake the author's `Thread:`. One fixer
  per repository at a time; a bounded number of fix rounds per chain (more for risky findings); then the supervisor
  thread.
- **Fix landing**: a `devfix/<sha>` whose trusted tests pass lands on dev / the default branch — unless it changes
  review machinery (contract rule (h)): then it is not landed and its authors are told to push it through a full review.
- **Overdue blocks**: dev blocked longer than `DEV_REVERT_AFTER_SEC` → the commits that touched the files named in the
  findings are reverted on dev (a new commit), their authors told first.
- **Main re-checks**: blocked main reviews go to the chain's owner, then (after `MAIN_OWNER_CLAIM_SEC`) to the strongest
  fixer agent. A finding pinned on a dispute-only commit (`Review-Fix-Of:`, no file changed) goes to the commit it
  disputes; such a commit is no hop of a repair chain.
- **Re-checks that failed before the code review** (the review job failed in its range, gates or setup steps; the
  blocking step never ran): infrastructure, not a finding — no owner or fixer is woken. The supervisor is told once per
  episode (`$STATE/infra-<step>`: the same failing step on the same main line until a main review completes again), with
  the step and a log excerpt; later heads of the episode are logged once each and settled by the next completed review.
  The same holds when the blocking step ran but the **reviewer itself did not** (`review-gate: reviewer failed: …` /
  `reviewer timed out` / `no parseable VERDICT` / `crashed`, and no finding, no gates error, no failed trusted tests —
  `review_infra_reason`): the alert names the step and the reviewer's failure and carries the `gh run rerun` command.
- **Dev reviews whose reviewer did not run** (same `review_infra_reason`): infrastructure, not a block — no fixer, no
  author notice, `dev.blocked_since` is neither started nor cleared and no revert / overdue notice fires for that head.
  The supervisor is told once per failed review attempt (notice key `infra.dev.<run>.<review job id>`: a rerun is a new
  job; repeated scans never repeat it; an undelivered alert is retried, a gone supervisor falls back to the CI owner),
  with the `gh run rerun <id> --failed` command; the next push to dev re-triggers the review too.
- **Pre-existing main findings in a dev review** (contract, Findings): a blocking finding whose culprit commit is already
  on main is recorded once in `$STATE/open-findings.log` (so the next reviews see it as known-open / pre-existing) and
  never routed on dev — no fixer, no fix round, no author notice, no `fixfailed`, no revert clock; only the head's other
  findings are routed (`dev_split_main`). Blocked only by such findings, the head lands like a passing review (the train
  and the head loop ask `review-passed.sh`, which decides from the trusted run with the same rule), and its tests are not
  cancelled when the review fails. There is no cross-chain "same problem" matching: main's own chain owns the finding.
- **Open findings**: findings whose fix rounds are spent are kept in `$STATE/open-findings.log`, which the review job
  passes to the reviewer (`open-findings-file`) so repeats are recognised as pre-existing.

## GitHub API budget

All of a host's dispatchers usually share one token (5000 REST calls/hour). `scripts/ci/gh-cache.sh` (sourced by the
dispatcher) splits the reads in two:

- **Approval evidence is never cached.** `gh` is always the real `gh` for reads. Everything that decides pass / land /
  deploy / complete reads through it, in the dispatcher's own process and in the contract scripts it runs:
  `review-passed.sh`, `merge-branch.sh`, `review-coverage.sh` (`review_verdict`, `review_attestation`, …),
  `review-runs.sh`, and the dispatcher's landing / train / devfix-tests / hotfix-complete / verdict checks
  (`run_verdict`, `review_jobs` → `recheck_reviewed`, the re-check's run record). One such jobs answer is read once
  per decision and handed to the helpers that need it, instead of being memoised. (Only when that answer shows a failed
  blocking step does `recheck_infra_failed` read the step's log through the memo, to tell a reviewer that never ran from
  a verdict: a completed job's log never changes, a rerun has new job ids, and the answer can only keep a head open.)
- **`ghm`, the per-run memo, only for routing and notification reads** of `review-dispatch.sh`: which runs exist and
  what is pending (`review_list`, `all_runs_list`, the dev CI listing) and the text of findings / notes / pre-existing
  findings, plus the range a re-check reviewed (`recheck_base`, attribution). Each dispatcher run gets a private
  directory (`GHC_RUN_DIR`, removed at exit); identical `ghm` reads within that run are asked once. Every write —
  `gh run rerun/cancel/delete`, `gh workflow run`, `gh api -X …`, any other `gh` command, `git push` (wrappers exported
  to child scripts) — wipes it. Stale by seconds at worst, which can delay an action by one dispatcher run, never
  approve one. `ghm` is not exported: a child script cannot reach the memo.
- **Completed jobs' logs** are kept across runs by job id (`$STATE/ghcache/logs/final.<job id>`; a re-run creates new job
  ids, so a completed job's log never changes), read through `ghm`: stored once a jobs answer of the same run showed
  the job completed more than two minutes ago, byte for byte. Unconfirmed logs are never memoised; confirmation
  triggers a new fetch before persistence. Old unversioned log files are ignored because they may contain prefixes.
  Nothing else outlives the dispatcher run.

Binary downloads (artifact zips, run log zips) and other endpoints pass through untouched. To make identical reads,
the dispatcher's listings use one request per filter set (`review_list`: 100 runs with every field its callers read;
`all_runs_list`). `test/ci/gh-cache-memo.sh` tests the rules — including the reviewers' re-run fixtures (run record,
workflow page, listing, failed write) within one dispatcher run and across runs, through `review_verdict` and
`review-passed.sh` as a dispatcher child — and enforces the split (only the routing readers above use `ghm`; no
approval script mentions it). `test/ci/review-dispatch-api-budget.sh` runs the whole dispatcher against a counting fake
`gh`: 18 calls cold, 5 on the next run of the same state.

## Settings

Required (no defaults — they are host and repository specific):

| Variable | Meaning |
|----------|---------|
| `REPO` | `owner/name` |
| `STATE` | the repository's state directory |
| `SRC` | a local clone of `REPO` (object store; every worktree below is detached) |
| `GH_TOKEN` | a token that can push to `REPO` and read its Actions runs |
| `T3_PROJECT` | the T3 project fixer agents start in |
| `SUPERVISOR_THREAD` | the thread that hears what no author can be told |
| `DISPATCH_THREAD` | the `Thread:` of the commits the dispatcher makes (the CI owner) |

Optional: `MAIN_BRANCH` (`main`), `SHEEPDOG_REVIEW_WORKFLOW` (the caller file, `review.yml`; `self-review.yml` for sheepdog
itself, [self-review.md](self-review.md)), `FIXER_PROVIDER` / `FIXER_MODEL`, `STRONG_FIXER_PROVIDER` / `STRONG_FIXER_MODEL` /
`STRONG_FIXER_EFFORT`, `FIXER_HOST_RULES` (host rules every fixer task states), `WAKE_URL` (the local wake relay for
Discord thread ids, default `http://localhost:3011`), `FIXER_WT_ROOT`, `FIX_ROUNDS_MAX`, `FIX_ROUNDS_MAX_RISK`,
`DEV_REVERT_AFTER_SEC`, `AUTHOR_FIX_WINDOW_SEC`, `MAIN_OWNER_CLAIM_SEC`.

## Contract scripts during a migration

The dispatcher calls `review-passed.sh` and `merge-branch.sh` inside `$STATE/trusted` (the repository's main, refreshed
every run, used for ancestry checks). For a repository whose main has `.github/sheepdog.yml` it uses sheepdog's own
copies (next to the dispatcher); for a repository not yet migrated it keeps using the repository's
`scripts/ci/` copies. Both kinds of runs are readable by sheepdog's scripts (job names with or without the
`<caller job> / ` prefix).

## A host wrapper (example)

```bash
#!/usr/bin/env bash
# /usr/local/bin/my-repo-review-dispatch — run by a timer every minute
set -euo pipefail
SD=/var/lib/sheepdog/trusted                      # a detached worktree of sheepdog's main
git -C /srv/git/sheepdog fetch -q origin main
[ -d "$SD" ] || git -C /srv/git/sheepdog worktree add -q --detach "$SD" origin/main
git -C "$SD" checkout -q --detach origin/main
export REPO=me/my-repo SRC=/srv/git/my-repo STATE=/var/lib/sheepdog/my-repo \
       T3_PROJECT=<project id> SUPERVISOR_THREAD=<thread id> DISPATCH_THREAD=<thread id>
GH_TOKEN=$(cat /etc/sheepdog/token); export GH_TOKEN
exec bash "$SD/scripts/ci/review-dispatch.sh" "$@"
```
