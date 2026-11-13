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
- **Fix landing**: a `devfix/<sha>` whose trusted tests pass lands on dev / the default branch.
- **Overdue blocks**: dev blocked longer than `DEV_REVERT_AFTER_SEC` → the commits that touched the files named in the
  findings are reverted on dev (a new commit), their authors told first.
- **Main re-checks**: blocked main reviews go to the chain's owner, then (after `MAIN_OWNER_CLAIM_SEC`) to the strongest
  fixer agent.
- **Open findings**: findings whose fix rounds are spent are kept in `$STATE/open-findings.log`, which the review job
  passes to the reviewer (`open-findings-file`) so repeats are recognised as pre-existing.

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
