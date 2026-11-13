# The review contract

What sheepdog guarantees about what lands on the default branch (called `main` below; `master` etc. work the same) and
what gets deployed. The workflow is [.github/workflows/review.yml](../.github/workflows/review.yml); the scripts are in
[scripts/ci/](../scripts/ci/); the contract's own test is `scripts/ci/test-review-contract.sh` (run by
`test/ci/review-contract*.sh`).

## Branches and trailers

- `dev` — the shared integration branch. Every change lands here first, as plain commits (no rebases of `dev`).
- `devfix/<sha>` — a fixer's repair of a blocked dev review of `<sha>`.
- `main` — moves only by fast-forward to a reviewed dev head (the merge train), by a `Train-Merge:` merge the
  dispatcher makes, or by a direct commit carrying `Hotfix: <reason>`.
- Every commit carries `Loop: <loop>`, `Thread: <author thread id>` and a `Verify:` checklist (`Verify:` alone on its
  line, then `- [x] <evidence>` lines). A fix of a blocked review carries `Review-Fix-Of: <full sha>`; a fixer that
  disagrees with a finding records `Review-Disputed: <finding #> <evidence>`; a main repair names
  `Fixes-Finding: #<n> <finding>` per finding.

## What runs for which push

| Push | tests | review |
|------|-------|--------|
| `dev` head | yes | yes |
| `devfix/*` head | yes | no (lands on its tests; main re-checks it, below) |
| `main` head with `Hotfix:`, `Train-Merge:` or `Review-Fix-Of:` | yes | yes (`recheck <sha>`) |
| `main` fast-forwarded to a reviewed dev head | no | no (its dev run is the proof) |

## The rules

- **(a) main re-checks everything since the last completed main review.** A `recheck` reviews
  `hotfix-review-base.sh HEAD..HEAD`: merge resolutions and the tests-only dev fixes a merge brought included. One main
  reviewer at a time (job-level concurrency): the running one finishes, only the newest waits, and a superseded waiting
  one is cancelled — its commits ride the next range.
- **(b) dev is reviewed once per commit.** A dev review covers everything since the last completed dev review that
  passed, or that blocked and is repaired in the range (`dev-review-base.sh`). A range of only `Review-Fix-Of:` repairs
  of blocked reviews is a **tests-only fix round**: the blocking step is skipped (never reported as a pass), the
  attestation says `kind: tests-only-fix`, and `review-passed.sh` re-checks from the trusted runs that every commit
  really repairs a completed, blocked review before it lets the fix land on green tests. Main then reviews the fix
  under (a).
- **(c) Coverage is a chain of completed reviews.** Each review uploads an attestation `{head, base, kind, main}`.
  `review-passed.sh <sha> [repo] [deployed sha]` approves a sha only when its trusted tests passed, its review step
  passed (or it is a valid tests-only round), and — given the deployed sha — the chain of attested ranges reaches from
  the deployed sha to `<sha>` with no gap; across a clean merge both parents must be covered.
- **(d) Only this run's attestation is uploaded**, also for a blocked review (a repaired blocked round is a link of the
  chain).
- **(e) Evidence is read only from trusted runs** (`review-runs.sh`): runs of the default branch's
  `.github/workflows/review.yml` started by a `workflow_run` event. A branch can add workflows, but never such a run.
  Job names are matched with or without the `<caller job> / ` prefix GitHub gives the jobs of a called workflow.
- **(f) No completed main review yet** → the first range starts at the deployed sha (the tag `deployed`, which each
  repository's deploy job moves after a successful deploy), not at ancient history.
- **(g) A tests-only fix lands only as a main head that main re-checks** (`merge-branch.sh` refuses any other
  landing of a tests-only approval), and its approval still holds after main advanced onto it (the attestation records
  the main boundary it was judged against).
- **(h) A tests-only approval never lands review machinery** (`scripts/ci/review-machinery.sh`: anything under
  `.github/` — the caller workflow and its sheepdog pin, `.github/sheepdog/tests.sh`, `.github/sheepdog.yml` —,
  `reviewer/`, `scripts/ci/`). The next default-branch run would already execute such a change (a new pin selects the
  workflow that is supposed to check it), so a devfix, a tests-only train candidate or a tests-only `merge-branch.sh`
  landing that touches it is refused; it goes through a full review (a dev commit, or a `Hotfix:` on main).

## Findings

The reviewer ends with one `VERDICT:` JSON line. Every finding has a severity — `blocker` and `should` block, `nit`
never does — and a finding about security, permissions, funds, data loss or concurrency is never a nit. A finding the
reviewer marks `preexisting` (not introduced or worsened by the range) never blocks; known open findings (the
dispatcher's list of findings whose fix rounds are spent) are passed to the reviewer so a repeat is recognised as
pre-existing. Each blocking finding names a route (`fixer` or `author`) and, when it can, the culprit commit.

`review-gate.ts` prints `review-gate: ROUTE …`, then per finding `review-gate: FINDING #n route=… commit=…`,
`review-gate: BLOCKED #n …` and `evidence: …`; the dispatcher reads those lines from the job log, together with the
`review-range: <base> <head>` line of the range step.
