# sheepdog prior art

> Researched 2026-11-13. Sources: each project's README / official docs / the GitHub API (stars, license and last push
> were checked that day). Details marked "(memory)" come from existing knowledge and were NOT re-checked against the
> docs that day; read the original before relying on them.
> Goal: find mechanisms worth borrowing for sheepdog (a public, reusable CI/CD + agent review system that private
> repositories call as sha-pinned reusable workflows).

## 0. Our pain points (numbered for reference below)

| # | Pain point |
|---|------------|
| P1 | Races on bash state files (a dispatcher cron every minute, several runners writing concurrently) |
| P2 | Bookkeeping drift between git trailers and state files |
| P3 | The reviewer reports the same pre-existing bug again and again |
| P4 | Merge commits bypass review |
| P5 | A tests-only fix that lands counts as "reviewed" |
| P6 | Runner queue priority (main must go before dev) |
| P7 | Flaky tests |
| P8 | Agent worktrees grow the disk |
| P9 | Test isolation (a test accidentally starts a real agent) |
| P10 | Prompt injection through repository content |
| P11 | (new) As a public reusable system: callers pin a sha, secrets/OIDC boundaries, config distribution |

---

## 1. Merge queues / gating

### 1.1 Zuul (OpenStack / OpenDev)
- **What**: OpenStack's project gating system, one of the originators of "test the merge result before merging";
  supports Gerrit and GitHub.
- **Worth borrowing**
  - **Dependent pipeline + speculative execution**: each change in the queue is tested as "branch tip + every change
    ahead of it"; A..E run in parallel, E's job merges A–D first, then tests E. All green → all merge at once. → Our
    merge train (dev→main) currently pushes one at a time; it could speculatively merge onto "main tip + the queue
    ahead", so the merge result itself is what is tested/reviewed — **this solves P4 directly** (the merge product can
    no longer escape, because the merged tree is what was tested).
  - **Failure handling**: C fails → A and B merge as usual, C is ejected, D and E rebuild on the tip and are retested
    (D's earlier failure is ambiguous). A clean state machine, more predictable than bash's "blocked > 60 min →
    revert" (P1/P2).
  - **TCP-like window**: default window 20, +1 per successful merge, halved per failure, with floor/ceiling. → With only
    2 self-hosted runners (tralyx-ib-1/2), an adaptive window limits speculative concurrency and avoids spinning while
    tests are flaky (P6/P7).
  - **Depends-On: footer**: cross-repo dependencies written in the commit message / PR description form a DAG (cycles
    refused by default). → sheepdog serves several private repos; the same kind of trailer can say "this tralyx change
    depends on sheepdog commit X".
  - **Config as code, trusted vs untrusted config**: Zuul separates config-projects (trusted, may define
    pipelines/secrets) from untrusted-projects (changes to job definitions are tested speculatively first and get no
    secrets) (memory). The same shape as our "the reviewer runs from main's trusted copy, repository content is
    untrusted data" (P10/P11).
- **Do not copy**: the whole Zuul stack (ZooKeeper + scheduler + executor + nodepool + Ansible) is heavy
  over-engineering for 2 runners; Gerrit-style "one review per change" UX does not fit agents pushing straight to dev.
- **License**: Apache-2.0
- **Links**: https://zuul-ci.org/docs/zuul/latest/gating.html , https://opendev.org/zuul/zuul

### 1.2 bors-ng / homu
- **What**: the "Not Rocket Science Rule" merge bot from the Rust community: merge the PR into a `staging` branch, test
  it, fast-forward main when green. **bors-ng was archived on 2024-04-04**; its README recommends GitHub merge queue.
  homu is Rust's earlier (Python) version.
- **Worth borrowing**
  - **staging branch + fast-forward**: main only ever fast-forwards to a tested merge commit. → Let sheepdog's merge
    train move `main` only to "the tree that both the tests and a review attestation cover", which removes P4 and P5
    structurally.
  - **Batch + bisection**: a failed batch is split in half and requeued until the bad PR is found; O(E log N). → When
    several agent commits ride the train together, a failure can be bisected to a specific commit/thread and routed to
    its owner (fits the dispatcher's owner routing).
  - **`try` branch**: the same merge+test flow that never advances main — a "dry run" for fixers (try before landing).
- **Do not copy**: the `bors r+` comment-command approval model (ours is an automatic review gate); its Elixir ops stack.
- **License**: bors-ng Apache-2.0 (homu MIT (memory))
- **Links**: https://github.com/bors-ng/bors-ng , https://graydon2.dreamwidth.org/1597.html (the Not Rocket Science Rule
  post (memory))

### 1.3 GitHub merge queue (native)
- **What**: GitHub's built-in merge queue, the successor of bors.
- **Worth borrowing**
  - Every PR gets a temporary branch `gh-readonly-queue/{base}/...` = base + every PR ahead of it; workflows listen for
    the `merge_group` event.
  - Parameters: build concurrency 1–100, group size min/max 1–100, minimum group wait, status check timeout; a failing
    PR is removed and the groups behind it are rebuilt; "jump the queue" rebuilds every running group.
  - **With "Only merge non-failing PRs" off**: a PR that failed on its own can still merge if the last PR of its group
    covers the combined result and passes — a tolerance for flakiness (P7).
  - → If sheepdog adopts a PR flow (instead of agents pushing to dev), it could **use the native merge queue as the
    execution layer of the merge train**, with sheepdog only providing the required checks (tests, review attestation).
    Far less hand-written bash state machine (P1). Note: the repo must be organization-owned or public, with rulesets
    enabled (memory).
- **Do not copy**: it does not fit a push-to-branch (no PR) workflow; to use it with our "push to dev + automatic merge
  to main" the dispatcher would have to open PRs automatically.
- **License**: proprietary (GitHub feature)
- **Link**: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue

### 1.4 Mergify
- **What**: a SaaS merge queue + PR automation (YAML rules). The open-source engine is no longer public
  (`Mergifyio/mergify-engine` is now only an issue tracker, last push 2023-09).
- **Worth borrowing**
  - **Priority rules**: put hotfixes in a higher-priority queue by label/condition, skipping regular work → our
    `Hotfix:` trailer (P6).
  - **Two-stage CI**: cheap tests on every push, expensive ones only in the queue → push to dev runs fast tests +
    review, the merge train runs everything.
  - **freeze** (no merges in a release window), **scopes** (partition by path: unrelated changes in a monorepo do not
    block each other), up to 128 speculative checks.
- **Do not copy**: SaaS dependency and per-seat pricing; an over-broad rule DSL.
- **License**: SaaS / proprietary (historical open parts Apache-2.0)
- **Link**: https://docs.mergify.com/merge-queue/

### 1.5 Kodiak
- **What**: a lightweight GitHub App that updates branches and merges by label.
- **Worth borrowing**: minimal config (`.kodiak.toml`); "update the branch only when needed" saves CI; checks the base
  is current before merging.
- **Do not copy**: no speculative testing; essentially a serial queue.
- **License**: **AGPL-3.0** (ideas only; do not copy its code into sheepdog)
- **Link**: https://github.com/chdsbd/kodiak

### 1.6 Aviator MergeQueue
- **What**: a commercial merge queue (limited open-source parts).
- **Worth borrowing** (memory; the concept pages were not fetched in detail that day): parallel mode (Zuul-like
  optimistic parallelism), **affected targets** (independent queues per affected target), batch + bisection,
  **fast-forward mode** (main only moves to tested commits, keeping linear history and commit shas, so an attestation
  points at the same sha), skip-the-line priority.
- **Do not copy**: closed commercial dependency.
- **License**: proprietary
- **Link**: https://docs.aviator.co/mergequeue

### 1.7 Uber SubmitQueue (paper, EuroSys'19 "Keeping Master Green at Scale")
- **What**: Uber's monorepo submit queue that keeps every master commit green.
- **Worth borrowing**: **speculation graph/tree + a probabilistic model**: predict each pending change's success
  probability from history and build the most likely combinations first; **conflict analysis** prunes, unrelated
  changes build in parallel. A 2025 follow-up, "CI at Scale: Lean, Green, and Fast", covers cost. → For sheepdog a
  simple heuristic can replace the model — e.g. "the deeper the Review-Fix-Of chain and the higher the author thread's
  recent failure rate, the later in line", and deciding from the file sets whether two commits can be verified
  independently (P6/P7).
- **Do not copy**: Uber-scale prediction models and build-graph analysis; not needed here.
- **Links**: https://www.uber.com/blog/research/keeping-master-green-at-scale ,
  https://blog.acolyer.org/2019/04/18/keeping-master-green-at-scale/ , https://arxiv.org/abs/2501.03440

### 1.8 Chromium CQ / LUCI Change Verifier (CV)
- **What**: Chromium's commit queue; CV, a LUCI microservice, runs presubmit tryjobs and submits the CL when all pass.
- **Worth borrowing** (details mostly from memory; the public README describes only the architecture):
  - `Commit-Queue +1` (dry run: test, no submit) vs `+2` (full run: test, then submit) → our "try" vs "train".
  - **Tryjob result reuse**: no rerun when the same patchset/tree already has a success → sheepdog caches test/review
    results by **tree hash** and reuses them when a rebase leaves the tree unchanged (saves runners, P6).
  - **Retry quota**: each run has a failure-retry budget (global / per builder / timeouts counted separately) → a
    bounded retry for flakes instead of endless retests (P7).
  - **Experimental builders**: run a percentage of builds on a new builder without blocking → a new reviewer prompt or
    model can run in "shadow mode" for a while before it becomes blocking.
- **Do not copy**: infrastructure deeply coupled to Buildbucket/Gerrit.
- **License**: Apache-2.0 (luci-go)
- **Link**: https://chromium.googlesource.com/infra/luci/luci-go/+/HEAD/cv/README.md

### 1.9 Mozilla Lando (autoland)
- **What**: Mozilla's landing service: applies Phabricator-reviewed patches and pushes them to the autoland repository;
  sheriffs then merge to central; it now supports Git too.
- **Worth borrowing**: **landing decoupled from the review tool**: Lando only "checks the review state → applies the
  patch → pushes", with landing checks first (e.g. security bugs, blocking reviewers); when sheriffs find a problem after
  landing they **back it out** (Mozilla's backout culture ≈ our auto-revert).
- **Do not copy**: Phabricator + Mercurial legacy.
- **License**: MPL-2.0
- **Link**: https://github.com/mozilla-conduit/lando

---

## 2. Kubernetes Prow + Tide

- **What**: the Kubernetes CI system. Prow handles webhooks/comment commands (`/retest`, `/lgtm`, `/approve`, `/hold`)
  and ProwJobs; Tide is the merge pool (replaced mungegithub's Submit Queue in 2017).
- **Worth borrowing**
  - **Tide's decision loop** (one pool per org/repo/branch): drop failing/conflicting/pending PRs → merge a successful
    batch if there is one → else merge a single successful PR → else start a new batch when nothing is pending → else
    retrigger the highest-priority stale PR → else wait. **A pure "read all state → compute the one action" loop** that
    re-derives state from GitHub every round instead of trusting local files. → **The dispatcher should become such a
    loop with no local source of truth (stateless reconcile), state derived from git + check runs** — directly easing
    P1 and P2.
  - **Tide keeps a status context on every PR** saying whether it is in the pool and what it lacks → sheepdog: one check
    run per commit, "sheepdog/gate", saying "waiting for tests / waiting for review / blocked by finding X / owner thread
    Y", visible to humans and agents.
  - **OWNERS files** (approvers/reviewers inherited per directory) → our "owner = the root author thread of the
    Review-Fix-Of chain" is a dynamic owner; a static OWNERS could be the fallback when the chain breaks.
  - **presubmit / postsubmit / periodic** jobs kept apart → dev push / after landing on main / scheduled (e.g. a
    periodic full review, worktree cleanup).
  - **`/retest` + flake handling**: Kubernetes has flakefinder / TestGrid flake reports; Prow jobs can set
    `max_concurrency`, and `/hold` blocks a merge.
  - **lifecycle plugin** (stale → rotten → close) resembles our "blocked > 60 min → auto-revert", but it is staged,
    visible, and can be interrupted with `/remove-lifecycle`.
  - **ProwJob is a CRD**: every job is a persistent object with a state machine, not a bash file → sheepdog's
    job/finding state belongs in **transactional storage** (SQLite WAL + a single writer, or GitHub check runs
    themselves).
- **Do not copy**: needs a Kubernetes cluster + ghproxy; a huge plugin system; comment-command UX is unnecessary for
  agents.
- **License**: Apache-2.0
- **Links**: https://docs.prow.k8s.io/docs/components/core/tide/ , https://github.com/kubernetes-sigs/prow

---

## 3. Gerrit

- **What**: Google's code review system, patchset-based, submission driven by voting labels.
- **Worth borrowing**
  - **Change-Id trailer**: a commit-msg hook generates `Change-Id: I<sha1>`, which identifies the same logical change
    across amend/rebase → our `Review-Fix-Of:` and `Fixes-Finding:` should reference **stable IDs** (finding id / change
    id), not commit shas that change on rebase (P2).
  - **Voting labels** (Code-Review -2..+2, Verified -1..+1, combined by Prolog / submit requirements) → sheepdog keeps
    "Tested" and "Reviewed" as **two independent labels/attestations on the same tree**, and submission needs both: a
    tests-only fix gets Tested, never Reviewed (**solves P5 directly**).
  - **copy rules**: votes survive a rebase that leaves the tree unchanged (trivial rebase / no code change) → no
    repeated review, and no "changed the code but inherited the old vote".
  - **Reviewing merge commits**: Gerrit shows a merge commit against its "auto-merge" by default (only what the conflict
    resolution introduced) (memory) → sheepdog must not skip merge commits; it should review "the actual merge result vs
    the automatic merge of the two parents" (P4).
  - **git notes for review metadata** (`refs/notes/review`, the reviewnotes plugin) (memory) → keep review/attestation
    records in notes or a separate ref instead of trailers that cannot be amended later (P2).
- **Do not copy**: the whole Gerrit server; Prolog submit rules.
- **License**: Apache-2.0
- **Links**: https://gerrit-review.googlesource.com/Documentation/user-changeid.html ,
  https://gerrit-review.googlesource.com/Documentation/config-labels.html

---

## 4. Reporting review results: reviewdog / Danger

### 4.1 reviewdog
- **What**: reports any linter's output (errorformat, SARIF, rdjson) as PR review comments / check annotations.
- **Worth borrowing**
  - **filter-mode**: `added` (default: only added/modified lines), `diff_context`, `file`, `nofilter`. → **Filter the
    reviewer's findings by the diff first: only findings inside this change block; findings outside it are downgraded to
    "pre-existing", recorded in a baseline, never blocking and never routed again** (**the core fix for P3**).
  - **rdjson, a generic diagnostic format**: severity, rule code, multi-line range, code suggestion → unify sheepdog's
    findings as rdjson/SARIF instead of free text, for de-duplication and machine routing.
  - **`-fail-level`**: none/info/warning/error decides the exit code → a configurable blocking threshold.
- **Do not copy**: it has no finding lifecycle (it does not know whether a finding was fixed); we need that ourselves.
- **License**: MIT
- **Link**: https://github.com/reviewdog/reviewdog

### 4.2 Danger (danger-js / danger-ruby)
- **What**: runs a `dangerfile` in CI that checks PR metadata (changed files, description, labels) and comments.
- **Worth borrowing**: **lint of the review process itself** — e.g. "src/ changed but no test changed → warn", "a commit
  without a `Thread:` trailer → fail", "`Hotfix:` needs `Verify:`". → sheepdog's trailer validity checks become a
  deterministic Danger-style rule step (before the LLM review), so bookkeeping problems fail early (P2/P5).
- **Do not copy**: a dangerfile is executable code in the repository — running it for fork PRs / untrusted input is RCE;
  sheepdog's rules must come from the trusted copy (P10).
- **License**: MIT
- **Links**: https://danger.systems/js/ , https://github.com/danger/danger-js

---

## 5. LLM review / agent fix loops

### 5.1 PR-Agent (formerly Qodo / CodiumAI)
- **What**: an open-source LLM PR assistant: `/review`, `/improve`, `/describe`, `/ask`; Qodo has donated it to the
  community (`The-PR-Agent/pr-agent`); the README says **MIT** (early versions were AGPL-3.0 — mind that when citing old
  code).
- **Worth borrowing**
  - **PR compression**: trims large diffs by file/language priority to fit a token budget → a fallback for us when an
    incremental review range grows too large (e.g. after dev stayed blocked for a long time).
  - **Layered config**: built-in `configuration.toml` + repo-level `.pr_agent.toml` (and an org-level global config
    (memory)) → sheepdog's reviewer config too gets "defaults → org → repo" layers, but **the repo layer may only
    tighten, never loosen** the blocking rules (P10/P11).
  - **One LLM call, structured JSON output** → structured, de-duplicable findings.
  - A security lesson: v0.36.1 disabled `/help_docs` over a credential leak — the fewer secrets an LLM tool can read,
    the better.
- **Do not copy**: it pastes PR content straight into the prompt, with no isolation treating repository content as
  untrusted data; the comment-driven interaction model.
- **License**: MIT (current)
- **Link**: https://github.com/The-PR-Agent/pr-agent

### 5.2 OpenHands (formerly OpenDevin)
- **What**: an open-source AI software engineering agent platform (93k stars, MIT) with a GitHub resolver: label an
  issue `fix-me` or mention `@openhands-agent` and it tries a fix and opens a draft PR (memory).
- **Worth borrowing**
  - **Sandboxed runtime**: every agent action runs in a docker sandbox, isolated from the host → our fixers should run
    in a throwaway container too (not a host worktree): worktree lifetime = container lifetime, **destroying the
    container cleans up (P8)**, and the container holds no real agent credentials (P9).
  - **max iterations / budget** limits, and **a draft PR instead of a direct merge** (agent output must pass the gate
    again) — consistent with "main re-reviews every fix".
  - **Runs only when triggered by a user with write access** (permission check) (memory) → the dispatcher acts only on
    findings from trusted sources.
- **Do not copy**: the full platform (frontend, session service) — we already have T3 threads.
- **License**: MIT (the `enterprise/` directory has its own license (memory))
- **Links**: https://github.com/OpenHands/OpenHands , https://docs.openhands.dev

### 5.3 SWE-agent
- **What**: the Princeton/Stanford issue→patch agent (MIT, NeurIPS 2024) that introduced the Agent-Computer Interface
  (ACI).
- **Worth borrowing**: **the ACI idea** — restricted commands with guardrails (e.g. lint after every edit, refuse an edit
  with a syntax error) are more reliable than a whole shell; **trajectory recording** (every step on disk, replayable) →
  archive fixer trajectories to analyse "why the same finding was fixed three times" (P3).
- **Do not copy**: a benchmark harness, not a CI product.
- **License**: MIT
- **Link**: https://github.com/SWE-agent/SWE-agent

### 5.4 Sweep
- **What**: once an "issue → PR" GitHub bot, now a JetBrains AI assistant; the GitHub API reports its license as
  NOASSERTION (non-standard).
- **Worth borrowing**: historical experience — an auto-PR bot that cannot run tests produces poor results; it later added
  a "run CI → read failures → fix again" loop (memory). So **a fixer must run the trusted tests before committing**.
- **Do not copy**: the code (unclear license, the project pivoted).
- **Link**: https://github.com/sweepai/sweep

### 5.5 GitHub Copilot Autofix
- **What**: generates fix suggestions for CodeQL alerts.
- **Worth borrowing**
  - **Input = a structured alert (SARIF) + limited code snippets**, not the whole repository → a fixer's prompt should
    center on the structured finding, with bounded context.
  - **Validation harness**: GitHub regression-tests autofix on 2300+ public alerts with test coverage: after applying,
    does the alert disappear, do new alerts appear, are there syntax errors, did the test output change → **sheepdog's
    fixer success criterion = the finding no longer reproduces + no new finding + the tests pass**, with our own
    reviewer/fixer regression set (P3/P5).
  - **No suggestion without enough confidence**; every suggestion is confirmed by a human (for us: main's re-review).
- **Do not copy**: closed source, tied to CodeQL; the official docs do not discuss prompt injection.
- **License**: proprietary
- **Link**: https://docs.github.com/en/code-security/code-scanning/managing-code-scanning-alerts/responsible-use-autofix-code-scanning

### 5.6 (addendum) SARIF partialFingerprints / "Clean as You Code" baselines
- **What**: SARIF 2.1's `partialFingerprints` let GitHub code scanning recognise the same alert after code moves;
  SonarQube's "new code" policy gates only new code; Semgrep has `--baseline-commit` (memory).
- **Worth borrowing**: **finding fingerprint = hash(rule/class + file + normalised relevant code snippet)**, stored in a
  baseline table; a newly reviewed finding whose fingerprint is in the baseline (pre-existing) or marked "won't fix /
  known" no longer blocks and is no longer routed (**P3**).
- **Links**: https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html ,
  https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning

---

## 6. Config as code and shared presets: Renovate

- **What**: a dependency update bot whose config-sharing system is the industry benchmark.
- **Worth borrowing**
  - **`extends` presets**: `github>org/repo` (reads `default.json`), `github>org/repo:name`,
    `github>org/repo//path/name`, sub-presets, **`#tag` version pinning**; relative references in nested extends inherit
    the parent preset's tag.
  - **Organization defaults**: onboarding looks up `{org}/renovate-config`'s `default.json` automatically.
  - **Preset parameters** `{{arg0}}`, `{{args}}`; **`ignorePresets`** (matched against the resolved absolute string).
  - → sheepdog's `.sheepdog.yml` could distribute review rules, test commands and deploy policy with
    `extends: ["github>yidongw/sheepdog-presets:node-service#<sha>"]`; **presets are pinned by sha too** and upgraded
    together with the reusable workflow pin (Renovate itself can open the PRs that bump sha pins) (P11).
- **Do not copy**: npm-hosted presets (no longer recommended upstream); Renovate's enormous config surface — sheepdog
  should have few settings.
- **License**: AGPL-3.0 (borrow the format and semantics only, never the code)
- **Link**: https://docs.renovatebot.com/config-presets/

---

## 7. Supply chain: SLSA / in-toto / Sigstore / GitHub artifact attestations

### 7.1 SLSA
- **What**: OpenSSF's build integrity framework (Build L1–L3; a Source track draft since v1.1 (memory)).
- **Worth borrowing**: the provenance field model (builder id, buildDefinition, resolvedDependencies), and L3's
  requirement that **the build platform is trusted and build definitions are isolated from tenants** → sheepdog's
  reviewer/test runner is the "builder"; its identity should be `sheepdog/.github/workflows/xxx.yml@<sha>`, not the
  calling repository.
- **License**: spec CC-BY / code Apache-2.0
- **Link**: https://slsa.dev/spec/v1.0/

### 7.2 in-toto
- **What**: a framework of signed statements about supply-chain steps; an attestation is a Statement (subject = a set
  of artifact digests) + predicateType + predicate; a layout describes "which steps, by whom, and how their outputs
  chain".
- **Worth borrowing**
  - **Every step as an attestation**: `sheepdog.dev/test-result/v1`, `sheepdog.dev/code-review/v1` (predicate: the
    review's base tree, head tree, model, prompt version, finding list), `sheepdog.dev/deploy/v1`. Subject = **tree hash
    / commit sha**.
  - **Layout-style verification**: before a deploy, verify that "every segment from the deployed sha to the sha to deploy
    is covered by some review attestation, and covers code, not only tests" — that is our existing "attestation
    chain"; in a standard format it can be checked by existing tools, and with **trees as the review range's base/head,
    merge commits are covered naturally (P4/P5)**.
  - Keep attestations as **the single source of truth** (OCI / the GitHub attestation API / `refs/notes`); trailers are
    only redundancy for humans (P2).
- **License**: Apache-2.0
- **Links**: https://github.com/in-toto/attestation , https://in-toto.io

### 7.3 Sigstore (cosign / gitsign / Rekor / Fulcio)
- **What**: keyless signing based on OIDC identity + a transparency log.
- **Worth borrowing**: **keyless signing with the GitHub Actions OIDC token**, the certificate carrying the workflow
  identity; **gitsign** can sign commits → verify "this merge commit really came from sheepdog's merge-train
  workflow".
- **Do not copy**: for private repositories, the public Rekor transparency log leaks metadata (repository name, workflow
  path) — use GitHub's private attestation storage or a self-hosted one; do not push to public Rekor by default
  (memory).
- **License**: Apache-2.0
- **Link**: https://docs.sigstore.dev

### 7.4 GitHub artifact attestations (`actions/attest`)
- **What**: GitHub-native Sigstore-signed attestations; the current docs use `actions/attest@v4` (formerly
  `attest-build-provenance`), which needs `id-token: write` and `attestations: write`; verified with
  `gh attestation verify -R org/repo`.
- **Worth borrowing**: **issue and verify attestations with zero self-hosted infrastructure**; `gh attestation verify`
  also supports `--signer-workflow` and similar flags to check that the signer is a specific (reusable) workflow
  (memory) → the deploy script deploys only commits for which "sheepdog@<pinned sha>'s review workflow signed a
  code-review attestation".
- **Do not copy**: mind availability and plan limits for private repositories (private repos need Enterprise Cloud
  (memory)); when unavailable, fall back to cosign with a self-managed key, or git notes.
- **License**: proprietary service (the action is MIT)
- **Link**: https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds

---

## 8. GitOps deploys: Argo CD / Flux (+ Argo Rollouts / Flagger)

- **What**: in-cluster controllers that continuously reconcile "the desired state declared in git" into the running
  state.
- **Worth borrowing**
  - **A reconcile loop + desired state in git**: the deploy target = a sha in a git ref/file; the controller converges
    on it, with observable "OutOfSync / Healthy / Degraded" → sheepdog's "tests-first auto-deploy" should write a
    `deploy/target` file or ref (advanced by the gate) and the deployer only reconciles it; **rollback = set that ref
    back**, with a naturally auditable history (P1/P2).
  - **Flux's OCI artifacts + cosign verification**: deploy only artifacts whose signature verifies (memory) → ties into
    the attestation checks of 7.x.
  - **Progressive delivery in Argo Rollouts / Flagger**: canary + automatic analysis (metrics) + automatic rollback →
    our 5-minute bot boot check could be formalised as an "analysis" step.
  - **sync waves / hooks** (PreSync migrations etc.).
- **Do not copy**: our deploy targets are Dokploy/docker compose, not Kubernetes; do not introduce Kubernetes for this.
  Borrow only the "desired-state ref + pull-mode reconcile" idea.
- **License**: Argo CD Apache-2.0, Flux Apache-2.0, Flagger Apache-2.0
- **Links**: https://argo-cd.readthedocs.io , https://fluxcd.io/flux/ , https://argoproj.github.io/rollouts/

---

## 9. Reusable workflow patterns and GitHub Actions security

- **Mechanics** (official docs)
  - Cross-repo calls use `owner/repo/.github/workflows/file.yml@ref`; **a full sha is the safest ref** (a tag wins over a
    branch of the same name, and tags can be moved); `uses` cannot be an expression; a reusable workflow must live at the
    top of `.github/workflows`.
  - At most 10 levels of nesting; no cycles.
  - **Secrets go only to the directly called workflow**; `secrets: inherit` works only within the same org/enterprise;
    a secret that is not passed is an empty string without an error (`required: true` only checks that it was passed).
  - Permissions along the call chain **can only stay the same or shrink**, never grow.
  - **OIDC**: the standard claims `sub` / `repository` / `ref` / `sha` describe **the caller**; `job_workflow_ref`
    (`org/repo/.github/workflows/file@ref`) describes **the called reusable workflow**. A cloud/Vault trust policy can pin
    `job_workflow_ref:yidongw/sheepdog/.github/workflows/review.yml@<sha>` → **only that version of sheepdog's review
    workflow can obtain the LLM API key / deploy credentials**; a workflow written in the calling repository cannot
    (the key to P10/P11).
- **"Pwn requests" with `pull_request_target` / `workflow_run`**: checking out and running PR head code in a context
  that has secrets hands the secrets to the attacker (GitHub Security Lab series) (memory). sheepdog's rule: a job that
  holds secrets never executes the reviewed code; the reviewer only reads code as data (we already do), and
  **`actions/checkout` uses `persist-credentials: false`**.
- **Static checkers**: **zizmor** (MIT) — template injection, over-broad permissions, persisted credentials, dangerous
  triggers, unpinned `uses`, cache poisoning, impostor commits, etc. (some audit names from memory); **actionlint** (MIT)
  syntax/expression checks; **StepSecurity harden-runner** (egress allow-list); **pinact / ratchet** (rewrite `@v4` to a
  sha automatically) (memory). → sheepdog's own CI must run zizmor + actionlint, and the caller workflow template it
  ships must itself pass zizmor.
- **How organizations share workflows**: workflow templates (starter workflows) in the `.github` repository; Required
  workflows → now **"Require workflows to pass" in rulesets** (an org forces a workflow in every repo, pinnable by ref)
  (memory); most organizations let Renovate/Dependabot open PRs that bump sha pins, keeping a `# v1.2.3` comment.
- **Do not copy**: `secrets: inherit` (over-grants; sheepdog declares the secrets it needs explicitly); pinning by tag
  or branch.
- **Links**: https://docs.github.com/en/actions/sharing-automations/reusing-workflows ,
  https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/using-openid-connect-with-reusable-workflows ,
  https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/ , https://github.com/zizmorcore/zizmor ,
  https://github.com/rhysd/actionlint

---

## 10. Flaky test quarantine: Trunk Flaky Tests / BuildPulse etc.

- **What**: upload JUnit results to a service that identifies flaky tests statistically and quarantines them
  automatically.
- **Worth borrowing** (Trunk docs)
  - **Only "Flaky" tests can be quarantined automatically, never "Broken" (consistently failing) ones** — telling flaky
    from really broken is essential.
  - **Exit-code override**: tests run and report as usual; the CLI asks whether each failing test is quarantined and,
    **if every failure is on the quarantine list, turns the exit code into 0**. Quarantined tests keep collecting data
    and leave the list automatically once healthy.
  - **Manual override**: Always / Never Quarantine, with an audit log.
  - Build errors (failures not in the JUnit output) are never quarantined → the process exit code is the backstop.
  - → sheepdog: the test step emits JUnit → a local/SQLite record of each test id's pass/fail history on "the same tree"
    (passing and failing on the same tree is hard evidence of flakiness) → the quarantine list lives in **trusted
    config** (a commit of the tested repository cannot add to it, or agents would bypass failures with quarantine) →
    quarantined failures do not block the gate but create a finding routed to the owner (P7).
- **Open-source alternatives/references**: pytest-rerunfailures, Bazel `flaky_test_attempts`, Jest `retryTimes`,
  Kubernetes TestGrid, Google's flakiness papers (memory).
- **Do not copy**: SaaS dependency (Trunk and BuildPulse are proprietary); unlimited retries.
- **License**: proprietary (Trunk Analytics CLI etc.)
- **Links**: https://docs.trunk.io/flaky-tests/quarantining , https://buildpulse.io

---

## 11. Runner queues and priority: Buildkite / GitHub runners

- **Buildkite**: every step can set `priority:` (an integer; higher is picked up first, default 0); agents choose a
  queue with the `queue=` tag (memory; the docs page was not fetched in detail that day).
- **GitHub Actions**: **no native job priority**; self-hosted runners match by label, roughly FIFO (memory). Options:
  - **Lanes by label**: e.g. `tralyx-ib-1` takes only `sheepdog-main`, `tralyx-ib-2` takes `sheepdog-main` +
    `sheepdog-dev` → main always has dedicated capacity (P6).
  - **A `concurrency:` group + `cancel-in-progress`**: a new dev push cancels the old dev run (main queues instead);
    a concurrency group is also a **GitHub-hosted mutex** that can replace some bash lock files (P1).
  - **actions-runner-controller (ARC) / runner scale sets**: queues per scale set, ephemeral runners destroyed after
    use → also fixes leftover worktrees/disk (P8).
  - A home-grown "scheduler": the dispatcher triggers dev's `workflow_dispatch` only when main's queue is empty
    (pull mode), i.e. priority on top of GitHub.
- **Links**: https://buildkite.com/docs/pipelines/configure/managing-priorities ,
  https://docs.github.com/en/actions/using-jobs/using-concurrency , https://github.com/actions/actions-runner-controller

---

## 12. Other strong precedents (brief)

| Project | What to borrow | Pain | License |
|---------|----------------|------|---------|
| **Graydon's "Not Rocket Science Rule"** | "automatically maintain a repository of code that always passes all the tests" — only a tested merge result may reach main | P4 | blog post |
| **git interpret-trailers / git notes** | the standard trailer parser (do not grep trailers yourself); notes add review records without changing the commit, and `refs/notes/*` can be pushed | P2 | GPL-2.0 (git) |
| **GitHub Checks API** | a check run has `external_id`, annotations, `actions` (buttons); every gate result as a check run, visible and usable by branch protection | P2 | — |
| **SQLite WAL + a single writer** / Postgres advisory locks | replace bash state files: the dispatcher uses transactions + unique constraints so "a finding is routed exactly once" | P1 | public domain |
| **Temporal / durable workflows** (the idea) | timers like "steer after 30 minutes, otherwise start a fixer" as durable workflows instead of cron scans (memory) | P1 | MIT |
| **The Kubernetes controller pattern** (level-triggered) | recompute the desired state from the source every round; idempotent actions; no reliance on edge events | P1/P2 | Apache-2.0 |
| **nsjail / gVisor / bubblewrap** | further isolation of reviewer/fixer/test containers: read-only mounts, no network or an egress allow-list | P9/P10 | Apache-2.0 / LGPL |
| **CaMeL / the "dual LLM" pattern (prompt-injection research)** | the trusted LLM sees only structured data; the untrusted LLM reads repository content but has no tool permissions; outputs are schema-validated (memory) | P10 | paper |

---

## 13. What to borrow (by priority)

| # | Idea | Source | sheepdog component | Solves | Effort |
|---|------|--------|--------------------|--------|--------|
| 1 | **Trees as the object of review/test**: review range = the diff `last_reviewed_tree → new_tree`; merge commits compared as "actual result vs automatic merge"; results cached by tree hash | Gerrit, LUCI CV, Not Rocket Science | reviewer range / merge train | P4, P6 | M |
| 2 | **Two independent attestations (Tested / Reviewed)**, in-toto Statement format, subject = tree/commit; merging and deploying need both; a tests-only fix only gets Tested | Gerrit labels, in-toto | attestation module / deploy gate | P5, P2 | M |
| 3 | **One source of truth for attestation/finding state** (GitHub check runs + `refs/notes/sheepdog`, or SQLite); trailers only human-readable redundancy, kept consistent by Danger-style rules | Gerrit notes, Prow ProwJob, Danger | bookkeeping / dispatcher | P2 | M |
| 4 | **A level-triggered reconcile dispatcher**: every round derive state from git + check runs → compute the one action → execute idempotently; local state in SQLite transactions + unique constraints; `flock` for a single instance | Tide decision loop, Kubernetes controllers | dispatcher | P1, P2 | L |
| 5 | **Finding fingerprints + a baseline**: only findings inside this diff block (reviewdog `added`); fingerprints in the baseline / known / won't-fix are not routed again | reviewdog, SARIF partialFingerprints, Sonar new code | reviewer output post-processing | P3 | M |
| 6 | **Bind secrets with OIDC `job_workflow_ref`**: the LLM key and deploy credentials go only to `yidongw/sheepdog/.github/workflows/<x>.yml@<sha>`; callers pass no secrets; no `secrets: inherit`; a job with secrets never runs reviewed code | GitHub OIDC docs, pwn-request guide | reusable workflow interface / credential broker | P10, P11 | M |
| 7 | **Merge train as staging + fast-forward, bisecting failures**: main only fast-forwards to tested + reviewed commits; a failed batch is bisected to a commit → routed by owner | bors-ng, Zuul, Aviator FF | merge train | P4, P1 | M |
| 8 | **Flaky quarantine (trusted list + exit-code override)**: JUnit → a history table; passing and failing on the same tree = flaky; the quarantine list changes only in trusted config; Broken is never quarantined; a bounded retry budget | Trunk, LUCI retry quota | test runner wrapper | P7 | M |
| 9 | **Runner lanes**: a main-only label + a `concurrency` group (dev cancel-in-progress, main queues); the dispatcher triggers dev only when main is idle | Buildkite priority, GitHub concurrency | runner config / workflows | P6 | S |
| 10 | **Throwaway containers for fixers/reviewers**: the worktree inside the container, cleanup = destroying it; no real agent credentials in it, an egress allow-list; tests set `SHEEPDOG_FAKE_AGENT=1` to force stubs, and the real agent binary does not exist in the test container | OpenHands sandbox, ARC ephemeral runners, nsjail | fixer launcher / test harness | P8, P9, P10 | M |
| 11 | **Config presets `extends: github>org/presets:name#<sha>`**, three layers (sheepdog defaults → org → repo), the repo layer can only tighten; Renovate opens the PRs that bump sha pins | Renovate presets, PR-Agent config layers | `.sheepdog.yml` parser | P11 | S–M |
| 12 | **Shadow mode (experimental)**: a new reviewer prompt/model runs non-blocking in parallel first, finding quality is compared, then it becomes blocking; a reviewer/fixer regression set (commits with known findings) | LUCI experimental builders, Copilot Autofix harness | reviewer release process | P3, quality | M |
| 13 | **sheepdog's own CI runs zizmor + actionlint**, the caller template passes zizmor too; every `uses:` pinned by sha with a version comment | zizmor, actionlint, pinact | sheepdog repository CI | P11 | S |
| 14 | **A deploy target ref + reconcile**: the gate advances `refs/sheepdog/deploy/<env>`, the deployer converges in pull mode, rollback = resetting the ref; verify with `gh attestation verify --signer-workflow` before deploying | Argo CD/Flux, GitHub attestations | deployer | P2 | M |
| 15 | **Visible gate state**: one `sheepdog/gate` check run per commit saying what it waits for, which finding blocks it, and who the owner thread is (Tide status context) | Prow Tide | dispatcher / UI | P2, operability | S |

**Suggested first batch (within two weeks)**: #9, #13, #15 (S, immediate relief) → #1, #2, #5 (core correctness) →
#4, #6 (architecture; must be done before going public).

---

## 14. Name collision check: "sheepdog"

Searched: GitHub repository search (by stars), GitHub Marketplace (actions), the npm registry, PyPI.

| Where | Name | What | Collision |
|-------|------|------|-----------|
| GitHub **org `sheepdog`** (created 2013) | `sheepdog/sheepdog` ~1.0k★, GPL-2.0 | QEMU distributed storage (unmaintained, last push 2020-12); Fedora/Proxmox/OpenStack ship packages of that name | **High**: `github.com/sheepdog` is unavailable; it dominates search results |
| GitHub | `mainmatter/sheepdog` 120★, MIT, active | a Svelte/JS async task library ("herd your async tasks") | Medium (different domain, but active) |
| npm | `@sheepdog/core`, `@sheepdog/svelte`, `@sheepdog/vanilla` | the mainmatter project above, **holding the `@sheepdog` scope** | **High** (npm scope unavailable) |
| npm | `sheepdog` 1.0.1 (2017, a monorepo dependency checker, unmaintained) | inactive, but **the bare name is taken** | Medium |
| npm | `sheepdog-mcp` (2026-04 placeholder) | a ShepherdMCP.ai placeholder package | Low–medium (adjacent AI domain) |
| GitHub | `avantsoftware/sheepdog` (MIT, 2026-07) | **a Claude Code plugin**: blocks agent edits unless a matching skill was invoked ("no matching skill, no edit") | **Medium–high: the same AI coding agent governance domain** |
| GitHub | `kccarlos/herdr-sheepdog` (MIT, 2026-11) | a voice harness managing Herdr coding agents | Medium (AI agent domain) |
| GitHub | `uc-cdis/sheepdog` (Apache-2.0, active) | the Gen3 data submission API | Low |
| GitHub | `Contrast-Security-OSS/sheepdog`, `666OS/Sheepdog`, … | a WebGoat traffic generator, a macOS proxy tool | Low |
| PyPI | `sheepdog` 0.2.3 (2015, a GridEngine tool) | unmaintained | Low–medium (bare name taken) |
| GitHub Marketplace (actions) | a search for "sheepdog": **0 results** | — | none |
| GitHub account `sheepdog-ci` | the API returns 404 (currently free) | — | available |

**Conclusion and recommendations**
- "sheepdog" works as a **project name** (no Marketplace collision; the main namesakes are in storage/frontend), but
  **`github.com/sheepdog`, the `@sheepdog` npm scope and the bare npm/PyPI names are unavailable**; and two small
  namesakes already exist in the AI agent space, so search distinctiveness is mediocre.
- Recommendations:
  1. Keep the repository under the existing account: **`yidongw/sheepdog`** (simplest; reusable workflow references
     read `yidongw/sheepdog/.github/workflows/gate.yml@<sha>`).
  2. For a separate org: **`sheepdog-ci`** (currently available), repository `sheepdog-ci/sheepdog`; a Marketplace
     action name with a qualifier, such as "Sheepdog CI Gate".
  3. For a future npm/PyPI CLI: `sheepdog-ci` or `@<org>/sheepdog`, never the bare `sheepdog`.
  4. The docs' first sentence says "sheepdog — agent-native merge gate / CI for AI-authored code", to tell it apart
     from QEMU Sheepdog.

---

## Appendix: license quick reference (irrelevant when borrowing only designs; matters when copying code)

| Projects | License | Risk of copying code |
|----------|---------|----------------------|
| Zuul, Prow, Gerrit, bors-ng, luci-go, in-toto, Sigstore, Argo, Flux | Apache-2.0 | low (keep the NOTICE) |
| reviewdog, Danger, PR-Agent (current), OpenHands (core), SWE-agent, zizmor, actionlint | MIT | low |
| Lando | MPL-2.0 | file-level copyleft |
| Renovate, Kodiak | **AGPL-3.0** | **high: do not copy code** |
| Sweep | NOASSERTION | do not copy |
| GitHub merge queue, Mergify, Aviator, Trunk, BuildPulse, Copilot Autofix | proprietary | designs only |
