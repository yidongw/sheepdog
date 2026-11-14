# Reviewing sheepdog itself, and reviewing pin bumps

sheepdog is the code that tests and reviews every adopter. Two rules keep it under the same blocking review as the code
it guards.

## 1. sheepdog's own changes: the same flow as every adopter

- Changes land on `dev` (or `devfix/<sha>` for a review fix, or one `Hotfix:` commit on `main`). Nobody pushes `main`
  otherwise: the dispatcher fast-forwards it to a reviewed dev head (merge train), exactly as for an adopter.
- `ci.yml` runs on pushes to `main`, `dev` and `devfix/**`; `.github/workflows/self-review.yml` (named `Review`) is
  the caller and runs on `workflow_run` of CI. Like every adopter it pins the reusable workflow by a full sha — a
  sheepdog sha that already passed review. Never `./`: that resolves at main's latest commit, where a tests-only repair
  or a `Hotfix:` lands BEFORE its re-check, and it would run its own replacement of the review machinery on the review
  host. So a change to the reviewer, the gates or the workflow governs sheepdog's own review only after a pin bump in
  `self-review.yml`, and that bump is reviewed together with the sheepdog diff it ships (section 2): a bump on `dev`
  by the pinned (old) reviewer — dev runs use main's `self-review.yml` —, a `Hotfix:` bump on `main` by the new pin.
  Pinned: `5f54f10b5` (the review prompt reaches codex on stdin, never argv — a long range with prior findings passed
  Linux's 128 KiB per-argument limit, "spawn E2BIG"; before it, `5f7c3ce04`: the machinery repair classifier, a
  `Review-Fix-Of:` naming no ancestor is a warning, superseded dev blocks need no repair of their own).
- **The pin carries the current protections** (review of ad09c0b50 #1/#2: the pin e099da79f shipped the old range
  walker, so the reviewer that actually ran lacked the fix the candidate's tests demanded). `test/ci/self-review-pin.sh`
  runs every review-flow suite of the tree (all of `test/ci/` except the dispatcher's, which runs from the trusted main
  checkout) against the pinned snapshot; one it fails fails the tests. A new protection lands first (its suite named
  in `test/ci/self-review-pin.pending` for exactly the current pin, with the reason — a reviewed admission that the
  pin lags), then the pin bump, which drops the line: a pending line for another sha, or one the pin passes, fails.
  Bump the pin to the newest reviewed `main` whenever the review machinery changed there.
- The trusted test list is `.github/sheepdog/tests.sh` (every shell suite, the reviewer's typecheck and tests, the
  no-dependency check, and ci.yml's pinned actionlint and zizmor — merge authority needs them green too) on a GitHub-hosted runner. The review runs on a self-hosted runner (`sheepdog-review`) whose
  job-started hook admits only `workflow_run` jobs of main's `self-review.yml` of this repository; this repository is
  public, so fork pull requests (which run their own workflow files and could name any label) need approval for every
  external contributor.
- The caller's file name differs from adopters' (`review.yml` here is the reusable workflow), so every reader takes it
  from `SHEEPDOG_REVIEW_WORKFLOW` (default `review.yml`): the review job sets it from `github.workflow_ref`, the
  dispatcher wrapper for sheepdog exports `SHEEPDOG_REVIEW_WORKFLOW=self-review.yml`. Only runs of that one file,
  started by `workflow_run` on the default branch, are evidence.
- The host's trusted checkout of sheepdog (what every dispatcher runs) follows `main`, which now moves only after
  review.

## 2. A pin bump is reviewed together with the sheepdog change it ships

When an adopter's range changes the sha in its caller (`uses: yidongw/sheepdog/.github/workflows/review.yml@<sha>`),
the review job's step "sheepdog pin bump" (review.yml):

1. reads the pins at the range's base and head from the caller file (`.github/workflows/<caller>`), YAML-decoded
   (every `jobs.<id>.uses`, however quoted; comments do not count; the review runner needs python3 + PyYAML). An
   adoption commit (no pin at its base) is not a bump. It fails closed when the caller does not parse, when an
   existing pin is replaced by anything but one full sha, and when a bump sits in a tests-only fix round (a pin bump
   needs a full review);
2. requires the new pin to be an ancestor of sheepdog's `main` — `main` moves only through sheepdog's own reviewed
   train or a re-checked `Hotfix:` (section 1), so only a sheepdog commit that passed sheepdog's own review can be
   pinned; otherwise the review job fails (no pass);
3. writes `git diff old new` and `git log --stat old..new` of sheepdog (from sheepdog's own history, never from the
   candidate) and hands them to the reviewer (`--pin-*` arguments of `review-gate.ts`): the files are mounted read-only
   into the reviewer's container and the prompt asks for that diff to be reviewed with the same rules — a weakened
   gate or review there is a `regression`. `review-gate.ts` takes the `--pin-*` arguments all or nothing, each valid
   (exit 2 otherwise).

The pinned version that runs is the default branch's: a pin bump pushed to `dev` is reviewed by the OLD pinned
sheepdog (which must already contain this step — every pin from this feature on does); a `Hotfix:` that bumps the pin
on the default branch is re-checked by the new one, with the same step.

Tests: `test/ci/pin-bump.sh` (the step on fake histories: bump on main → diff + log + `--pin-*`; bump off main →
failure; no bump / adoption / comment → nothing), `reviewer/test/reviewer.test.ts` ("sheepdog pin bump": the prompt
block, the read-only binds), `test/ci/review-workflow-name.sh` (the caller file name rule).
