# sheepdog

**sheepdog — an agent-native merge gate: trusted tests, commit gates and a blocking, isolated LLM code review for
every pushed commit, plus the dispatcher that merges what passed and routes what did not.** (Not related to the QEMU
Sheepdog storage project.)

sheepdog is built for repositories where AI coding agents push most of the commits. Agents push to a shared `dev`
branch (or straight to the default branch with a `Hotfix:` trailer); nobody opens pull requests. For every push:

1. **Trusted tests** run the default branch's test list against the pushed commit, with a read-only token.
2. **Commit gates** check every new commit: `Loop:` / `Thread:` / `Verify:` trailers (so a finding can always reach
   the agent that wrote the code), no binary over 1 MB.
3. **A blocking review**: a cold, adversarial Codex session reviews the range since the last completed review, in a
   read-only, network-less container that treats the repository as untrusted data. Its verdict is a commit status and
   a log the dispatcher reads.
4. **The dispatcher** (a host job, every minute) fast-forwards the default branch to dev heads whose tests and review
   passed, wakes a fixer agent (or the author) with the findings of a blocked review, lands fixes, merges hotfixes back
   into dev, and reverts what stays blocked too long.

Every rule above is in this repository, once. A repository adopts it by calling sheepdog's reusable workflow pinned by
a full commit sha; nothing is copied into the repository except a short caller workflow and its test script.

## What is here

| Path | What |
|------|------|
| [.github/workflows/review.yml](.github/workflows/review.yml) | The reusable workflow (`on: workflow_call`): `tests`, `review`, `status` jobs |
| [reviewer/](reviewer/) | The isolated reviewer (`review-gate.ts`, `reviewer.ts`). No runtime dependencies: Node.js runs it as TypeScript |
| [scripts/ci/](scripts/ci/) | The review contract in bash: range selection (`hotfix-review-base.sh`, `dev-review-base.sh`), the trusted-run rule (`review-runs.sh`), the merge authority (`review-passed.sh`, `review-coverage.sh`, `review-repair.sh`, `merge-branch.sh`), the review ledger (`prior-findings.sh`), commit gates, and the dispatcher (`review-dispatch.sh`, `review-notify.sh`, `t3-mcp.sh`) |
| [test/](test/) | Shell suites over fake git histories and a fake GitHub API (`bash test/run.sh`); the reviewer's vitest suites live in `reviewer/test/` |
| [examples/.github/](examples/.github/) | What an adopting repository adds |
| [docs/](docs/) | [The review contract](docs/contract.md), [adopting sheepdog](docs/adopting.md), [the dispatcher](docs/dispatcher.md), [security model](SECURITY.md), [roadmap](docs/roadmap.md), [prior art](docs/reference/) |

## Adopting sheepdog (short version)

Full guide: [docs/adopting.md](docs/adopting.md).

1. Add `.github/workflows/ci.yml` — a trigger only ([example](examples/.github/workflows/ci.yml)).
2. Add `.github/workflows/review.yml` calling sheepdog **by a full commit sha**
   ([example](examples/.github/workflows/review.yml)):

   ```yaml
   jobs:
     sheepdog:
       uses: yidongw/sheepdog/.github/workflows/review.yml@<40-char sha>
       with:
         tests-runs-on: '["self-hosted","my-repo-tests"]'
         review-runs-on: '["self-hosted","my-repo-review"]'
   ```

   Keep the path `.github/workflows/review.yml` and the run name `review <sha>` / `recheck <sha>`: the verdict readers
   identify trusted runs by them.
3. Add `.github/sheepdog/tests.sh` (the trusted test list; [example](examples/.github/sheepdog/tests.sh)) and
   `.github/sheepdog.yml` ([example](examples/.github/sheepdog.yml)).
4. Provide the runners: a test runner (any isolated machine) and a review runner with Docker, the `codex` CLI and a
   loopback model endpoint (see [docs/adopting.md](docs/adopting.md#the-review-runner)).
5. Run the dispatcher for the repository from a trusted checkout of sheepdog ([docs/dispatcher.md](docs/dispatcher.md)).

Upgrading = changing the pinned sha in one line, through the same review as any other change.

## Security model (short version)

Full model: [SECURITY.md](SECURITY.md).

- The caller workflow runs from the default branch (`workflow_run`), so a branch cannot change what tests or reviews it;
  the reusable workflow refuses to run unless the caller pinned it by a full commit sha.
- No secrets cross the boundary: callers pass none (`secrets: inherit` is never used); the model credential stays on the
  review host and is added by a host-side relay that only forwards the model API.
- The job that runs candidate code (`tests`) has a read-only token and no secrets; the job that holds a write token
  (`review`, commit statuses only) never runs candidate code — it diffs it and hands it to the isolated reviewer.
- The reviewer's prompt states that everything in the repository is untrusted data; instructions found in it are
  themselves a finding. Agent instruction directories of the reviewed tree are hidden from the reviewer.
- sheepdog's own CI runs only on GitHub-hosted runners, with no secrets, and runs actionlint and zizmor.

## Development

```sh
bash test/run.sh                       # shell suites (needs git, jq, python3 + PyYAML)
cd reviewer && npm ci && npx tsc --noEmit && npx vitest run
```

Every behavior change comes with a test that fails before it and passes after it.

## License

Apache-2.0 — see [LICENSE](LICENSE).
