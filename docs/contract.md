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
  `Fixes-Finding: #<n> <finding>` per finding. For the dispatcher's routing of a blocked main commit, a repair covers
  exactly the findings its `Fixes-Finding:` / `Review-Disputed:` lines number (one with no such line covers them all);
  the uncovered ones stay routed — landing still needs only one effective repair. A repair on main of a finding's culprit
  commit (its `commit=`, an ancestor of the blocked commit), made after it, covers it too — when one of its lines carries that
  finding's text (its numbers belong to the culprit's own review), or when it has no such line; otherwise the fixer
  records the existing repair in an empty commit `Review-Fix-Of: <blocked sha>` with `Fixes-Finding: #<n> <text> (repaired by <sha>)`. A `Review-Fix-Of:` that names no ancestor of its commit is ignored with a
  warning (never a range abort): that commit is reviewed as an ordinary commit and gets no repair privilege — no
  tests-only round, no repair of a blocked round (`review-repair.sh`), no previous-round ledger.

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
- **(b) dev reviews every commit exactly once.** A dev review covers everything since the most recent COMPLETED dev
  review of an ancestor of the head, whatever its verdict — passed, blocked, or a tests-only fix round
  (`dev-review-base.sh`); while that ancestor's review is still running, the range step waits for it. A blocked commit
  is therefore never reviewed again by the next push's review, and a new commit after a blocked one is reviewed alone.
  Commits that reached dev through a main→dev merge are main's (main re-checks them, (a)): they are in no dev commit
  list or diff — the reviewer diffs against a virtual (never published) merge of the cover base with the main commit
  the head contains, and the attestation records that main side as `mainside`. A range of only `Review-Fix-Of:`
  repairs of blocked reviews (plus clean main merges) is a **tests-only fix round**: the blocking step is skipped
  (never reported as a pass), the attestation says `kind: tests-only-fix`, and `review-passed.sh` re-checks from the
  trusted runs that every commit really repairs a completed, blocked review before it lets the fix land on green tests.
  A repair counts only within its blocked review: every line it removes or changes must come from that review's range
  (or from an earlier repair of the round), and a revert is never a repair — otherwise the round is a full review of
  those repair commits (review of fb6bb396e #1/#2: a "repair" undoing a passing commit's auth fix). A tests-only round
  whose trusted tests failed is no base and no link (its commits ride the next review), and once main's re-check of a
  landed fix blocks, the fix's tests-only approval no longer stands. Repairs whose landing would change review
  machinery get a full review of those repair commits only (rule (h)).
  Main then reviews the fix under (a). Because no later dev review vouches for a blocked commit, approval does:
  landing a dev sha (`merge-branch.sh`, the merge train, a devfix landing) needs the coverage chain (c) from main to
  it, and a blocked review is a link of that chain only with an effective repair of it on the head.
- **A commit's verdict is its FIRST completed, attested verdict** (owner 11-16; `review-evidence.sh`
  `review_first_verdict`, the one reader every consumer uses: `review-passed.sh`, `review-coverage.sh`,
  `dev-review-base.sh`, `hotfix-review-base.sh`, `prior-findings.sh`, the dispatcher). The trusted runs of the commit
  ("review <sha>" / "recheck <sha>") are ordered by run id, then run_attempt — monotonic GitHub fields, never timestamps
  or the listing order — and the first attempt whose review job ran to a verdict decides: a pass (blocking step
  succeeded AND the run's attestation is valid for the sha — an unattested pass is no verdict), a block (the reviewer's
  `review-gate: BLOCKED #n` in the step that ran), or a tests-only fix round. Crashes, cancels and infrastructure
  failures have no verdict and are skipped. An earlier run that cannot be read (or has not finished) makes the verdict
  unknown, which is treated as blocked (fail closed; the next dispatcher run asks again). Later runs and reruns never
  change a verdict: a blocked commit is cleared only by an effective `Review-Fix-Of:` repair. Main's own verdict of a
  commit (its first "recheck <sha>") is the separate after-the-fact check: its block routes to a main fix chain and
  withdraws a tests-only approval (rule (g)). Each attempt uploads its own attestation (`review-attestation-<attempt>`,
  with `run_id` / `run_attempt` inside): a verdict is bound to its attempt's range, and a legacy run-wide
  `review-attestation` counts only for a run that was never rerun. A run is never evidence about itself: the review job
  reading verdicts skips its own unfinished attempt (`REVIEW_SELF_RUN`). The dispatcher completes a main head only on
  `review-passed.sh`'s answer for its main verdict (`REVIEW_PASSED_MODE=recheck`: every page of the listing, the run
  concluded success, its tests passed); an unknown main verdict waits for the next run.
- **A commit with nothing of its own is covered from what it equals**: no non-merge commit beyond the anchor and a tree
  identical to the anchor-side commit it contains (a "merge main into dev" with main's tree) — whatever its own review
  said; the dispatcher's merge-only rule (tralyx e964c6539, 11-15).
- **A reverted repair repairs nothing** (`review-repair.sh`, also the dispatcher's `fix_reverted`): a standing direct
  revert of the repair, or ANY merge revert after it. Conservative by policy: any merge revert after a repair forces a
  full review instead of trusting the repair; it costs one extra review and never approves unreviewed code.
- **(c) Coverage is a chain of completed reviews.** Each review uploads an attestation `{head, base, kind, main}`
  (`mainside` too when a dev range brought main commits in). `review-passed.sh <sha> [repo] [deployed sha]` approves a
  sha only when its trusted tests passed, its review step passed (or it is a valid tests-only round), and — given the
  deployed sha (main's sha when landing) — the chain of attested ranges reaches from the deployed sha to `<sha>` with
  no gap: a link is a review that passed or that blocked and is repaired on `<sha>` (`review-repair.sh`), or a
  tests-only round whose range re-checks as repairs of blocked reviews (against the main boundary it recorded); a
  `mainside` must be covered in its own right; across a clean merge both parents must be covered. Main's own range
  producer never starts at a tests-only round (main re-checks the fix).
- **(d) Only this run's attestation is uploaded**, also for a blocked review (a repaired blocked round is a link of the
  chain).
- **(e) Evidence is read only from trusted runs** (`review-runs.sh`): runs of the default branch's
  `.github/workflows/review.yml` started by a `workflow_run` event. A branch can add workflows, but never such a run.
  Job names are matched with or without the `<caller job> / ` prefix GitHub gives the jobs of a called workflow.
- **(f) No completed main review yet** → the first range starts at the deployed sha (the tag `deployed`, which each
  repository's deploy job moves after a successful deploy), not at ancient history.
- **(g) A tests-only fix lands only as a main head that main re-checks** (`merge-branch.sh` refuses any other
  landing of a tests-only approval, and of a reviewed head whose coverage chain passes through a tests-only round main
  has not re-checked yet — the merge train lands the fix head first), and its approval still holds after main advanced onto it (the attestation records
  the main boundary it was judged against).
- **(h) A tests-only approval never lands review machinery** (`scripts/ci/review-machinery.sh`: anything under
  `.github/` — the caller workflow and its sheepdog pin, `.github/sheepdog/tests.sh`, `.github/sheepdog.yml` —,
  `reviewer/`, `scripts/ci/`). The next default-branch run would already execute such a change (a new pin selects the
  workflow that is supposed to check it), so a devfix, a tests-only train candidate or a tests-only `merge-branch.sh`
  landing is refused when its LANDING TREE differs from main's in any machinery file (`landing_machinery_files`: the
  blocked base's own changes and a merge that rolls main's machinery back count too); it goes through a full review
  (a dev commit, or a `Hotfix:` on main). The classification uses the same definition: a dev range of only repairs whose landing would change
  machinery is never a tests-only round (`dev-review-base.sh --only-fixes`), so such a repair on dev gets the full
  review the guard asks for (review of dev c6dfe26bb #3: otherwise neither a review nor a landing could happen).

## Findings

The reviewer ends with one `VERDICT:` JSON line. Every finding has a severity — `blocker` and `should` block, `nit`
never does — and a finding about security, permissions, funds, data loss or concurrency is never a nit. A finding the
reviewer marks `preexisting` (not introduced or worsened by the range) never blocks; known open findings (the
dispatcher's list of findings whose fix rounds are spent) are passed to the reviewer so a repeat is recognised as
pre-existing. Each blocking finding names a route (`fixer` or `author`) and, when it can, the culprit commit.

`review-gate.ts` prints `review-gate: ROUTE …`, then per finding `review-gate: FINDING #n route=… commit=…`,
`review-gate: BLOCKED #n …` and `evidence: …`; the dispatcher reads those lines from the job log, together with the
`review-range: <base> <head>` line of the range step.
