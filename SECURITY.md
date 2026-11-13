# Security model

sheepdog is public and is called by private repositories. This file states what it relies on and what it guarantees.
Report a vulnerability privately through GitHub's "Report a vulnerability" (Security tab) of yidongw/sheepdog.

## Trust boundaries

| Component | Runs | Trusted? | Holds |
|-----------|------|----------|-------|
| Caller workflow (`.github/workflows/review.yml` of the repository) | the default branch's copy (`workflow_run`) | yes | — |
| sheepdog's reusable workflow, scripts, reviewer | the full commit sha the caller pinned | yes | — |
| The pushed commit (`candidate`) | data in `review`; executed only in `tests` | **no** | — |
| `tests` job | candidate code | **no** | a read-only `GITHUB_TOKEN` |
| `review` job | sheepdog's code only | yes | `GITHUB_TOKEN` with `statuses: write`, `actions: read`, `contents: read` |
| The reviewer (codex in Docker) | an LLM reading the candidate | **no** (its output is parsed, never executed) | nothing: no network, no credentials |
| The host relay (review runner) | sheepdog's code | yes | the model provider's bearer token (from the runner's codex config) |
| The dispatcher (a host job) | a trusted checkout of sheepdog's main | yes | a push token for the repository |

## Rules the code enforces

1. **Pinning.** The `review` job looks up its own reference in GitHub's record of the run (`referenced_workflows`) and
   fails unless the caller referenced sheepdog by a full commit sha; it then checks out exactly that sha. Callers cannot
   point it at other code through an input.
2. **No secrets cross the call.** sheepdog's workflow declares no secrets; callers pass none, and `secrets: inherit` is
   never used (checked by `test/ci/workflow-wiring.sh`). The model credential lives on the review host only.
3. **A job with write access never executes candidate code.** `tests` (executes it) has `contents: read` and no
   secrets; `review` (status write) only runs git, sheepdog's scripts and the containerised reviewer. Checkouts never
   persist credentials. No workflow expression is interpolated into a shell script (values pass through `env`).
4. **The reviewer is isolated.** `docker run --network none --read-only --cap-drop ALL --security-opt no-new-privileges`,
   the checkout mounted read-only, the reviewed tree's `.agents/.codex/.claude/.cursor` directories masked, a
   credential-free allow-listed copy of the codex config; the host relay forwards only `POST <base>/responses` and
   `GET <base>/models`, bounded in count and size, and adds the bearer token itself.
5. **Repository content is data.** The prompt says so, says that instructions inside the repository are a finding, and
   that weakening checks (tests, CI, gates) without a verified reason is a finding. Previous findings and known open
   findings are passed as fenced data with control characters and backticks removed.
6. **Verdicts come only from trusted runs.** Readers accept only `workflow_run` runs of the default branch's
   `.github/workflows/review.yml`; a branch can create other runs, never these.
7. **The repository can only tighten.** Inputs add gates and choose runners and toolchains; none disables a gate or the
   review.

## sheepdog's own CI

Runs on GitHub-hosted runners only, for pushes and pull requests alike, with `contents: read` and no secrets; no
self-hosted runner ever runs this repository's branches or pull requests. Every third-party action is pinned by a full
commit sha; actionlint and zizmor (checksum / hash pinned) check every workflow, including the examples callers copy.
