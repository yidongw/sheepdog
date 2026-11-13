# Roadmap

Milestone 1 (done): one public repository holding the whole system that each repository used to copy — the reusable
review workflow, the isolated reviewer as a standalone package, the review contract scripts, the dispatcher, and their
tests — with behavior parity, so repositories migrate one at a time by calling it pinned by sha.

The next milestones come from the prior-art research ([reference/prior-art.md](reference/prior-art.md) §13). They are
not built yet.

## M2 — trees as the object of review and test (prior art #1)

The reviewed range becomes `last reviewed tree → new tree`; a merge commit is reviewed as "the actual merge result vs
the automatic merge of its parents" instead of being followed through its parents; test and review results are cached
by tree hash, so a rebase that leaves the tree unchanged reuses them. Removes the remaining ways a merge resolution can
escape review (P4) and saves runner time (P6).

## M3 — separate Tested and Reviewed attestations (prior art #2, #3)

Two independent attestations per tree (in-toto Statement format; subject = tree/commit): `Tested` from the tests job,
`Reviewed` from the review job. Landing and deploying need both to cover the range; a tests-only fix gets only
`Tested` (P5). The attestations become the single source of truth; trailers stay as human-readable redundancy that a
deterministic rule checks for consistency (P2). Possibly signed with `actions/attest` / Sigstore and verified with
`gh attestation verify --signer-workflow` where the plan allows it.

## M4 — a reconcile-loop dispatcher with SQLite state (prior art #4, #15)

The dispatcher becomes level-triggered: every round it derives the state from git + the trusted runs, computes the one
next action per repository, and executes it idempotently; its own bookkeeping moves from marker files to SQLite (WAL,
one writer, unique constraints such as "a finding is routed once") (P1, P2). Each commit gets a `sheepdog/gate` check
run saying what it waits for and who owns it.

## M5 — finding fingerprints and a baseline (prior art #5)

Findings become structured records with a fingerprint = hash(class + file + normalised code snippet). Only findings
inside the reviewed diff block; a fingerprint in the baseline (pre-existing, known, won't fix) is recorded but never
blocks or routes again (P3). Replaces today's "known open findings" title list.

## Later

- Credential brokering bound to OIDC `job_workflow_ref` (prior art #6) for any secret sheepdog's jobs may one day need
  (today the model credential never leaves the review host).
- Staging + fast-forward merge train with bisection of failed batches (#7).
- Flaky-test quarantine from a trusted list with exit-code override (#8).
- Throwaway containers for fixers (#10), shadow-mode reviewer releases with a regression set (#12), shared config
  presets pinned by sha (#11), a deploy-target ref reconciled by the deployer (#14).
