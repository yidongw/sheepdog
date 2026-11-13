# Adopting sheepdog

A repository adopts sheepdog with four files on its default branch, two runners and a dispatcher job on a host. Its
existing review history keeps counting: sheepdog's readers accept runs made before and after the switch.

## 1. Files in the repository

| File | Purpose | Example |
|------|---------|---------|
| `.github/workflows/ci.yml` | The trigger: a no-op job on every push to `dev`, `main` and `devfix/**`. It runs none of the branch's code. | [ci.yml](../examples/.github/workflows/ci.yml) |
| `.github/workflows/review.yml` | Runs on `workflow_run` of CI (always the default branch's copy) and calls sheepdog pinned by a full sha. | [review.yml](../examples/.github/workflows/review.yml) |
| `.github/sheepdog/tests.sh` | The trusted test list, run in a checkout of the pushed commit. | [tests.sh](../examples/.github/sheepdog/tests.sh) |
| `.github/sheepdog.yml` | Marks the repository as adopted (the dispatcher then uses sheepdog's contract scripts) and records its branches. | [sheepdog.yml](../examples/.github/sheepdog.yml) |

Keep the caller at `.github/workflows/review.yml`, named `Review`, with the `run-name` of the example: the trusted-run
rule (`scripts/ci/review-runs.sh`) and every reader look for runs of that file titled `review <sha>` / `recheck <sha>`.

### Inputs of the reusable workflow

| Input | Default | Meaning |
|-------|---------|---------|
| `tests-runs-on` | (required) | JSON `runs-on` for the tests of dev / devfix heads |
| `tests-runs-on-main` | `""` (= tests-runs-on) | JSON `runs-on` for the tests of default-branch heads (a lane of their own) |
| `review-runs-on` | (required) | JSON `runs-on` for the review and status jobs |
| `main-branch` / `dev-branch` | `main` / `dev` | Branch names |
| `tests-script` | `.github/sheepdog/tests.sh` | The trusted test list (read from the default branch) |
| `tests-timeout-minutes` / `review-timeout-minutes` | 60 / 90 | Job timeouts |
| `node-version` / `bun-version` | `24` / `""` | Toolchains set up before the tests (`""` = none) |
| `extra-gates` | `""` | A gate script on the default branch, run as `bash <path> <base> <head>` after sheepdog's gates (it can only add refusals) |
| `verification-dir` | `scripts/ci/commit-verification` | SHA-bound `Verify:` records for published commits, read from the default branch |
| `open-findings-file` | `""` | Path on the review runner of the dispatcher's open-findings log |
| `reviewer-env-file` | `""` | Path on the review runner of the reviewer's `CODEREVIEW_*` settings |

A repository may only tighten what sheepdog checks: extra gates add refusals, the test list is the repository's own,
and nothing an input can say turns a gate or the review off.

## 2. Runners

### The test runner

Runs the candidate's code (`tests.sh`), so it should be a machine with nothing to steal: no deploy credentials, no
access to production, ideally reset between jobs. The job has a read-only `GITHUB_TOKEN` and no secrets.

### The review runner

Runs no candidate code. It needs:

- Docker, with the image `alpine:3.20` present (`docker run --pull=never`), and `socat` on the host's `/usr`;
- the `codex` CLI (its npm package; the native binary is mounted read-only into the container);
- a codex home (`CODEREVIEW_CODEX_HOME`) whose `config.toml` names a provider on a **loopback** `base_url` — the
  reviewer relays exactly that endpoint into the network-less container through a unix socket, and adds the provider's
  bearer token on the host side, so no credential enters the container;
- optionally a settings file (`reviewer-env-file`, or `SHEEPDOG_ENV_FILE` in the runner's environment) with
  `CODEREVIEW_CODEX_HOME`, `CODEREVIEW_EFFORT`, `CODEREVIEW_MODEL`, `CODEREVIEW_TIMEOUT_MS`.

The review runner gets a token with `statuses: write` and `actions: read` for its repository only.

## 3. The repository's settings on GitHub

- Actions must be allowed to use actions and reusable workflows from `yidongw/sheepdog` (Settings → Actions → General,
  "Allow all actions and reusable workflows", or an allow-list containing `yidongw/sheepdog/*`).
- Optionally protect `main` with the `review/blocking` status. The status is a convenience; the authority is
  `review-passed.sh`, which reads the trusted runs themselves.

## 4. The dispatcher

See [dispatcher.md](dispatcher.md): one timer per repository on a host, running sheepdog's `review-dispatch.sh` from a
trusted checkout of sheepdog's main with the repository's settings.

## 5. Deploys

sheepdog does not deploy. A deploy job should deploy only a sha for which
`REPO=<owner/name> scripts/ci/review-passed.sh <sha> <owner/name> <deployed sha>` succeeds (tests passed, review passed,
and the attested ranges cover everything since the deployed sha), and after a successful deploy move the tag
`deployed` to the deployed sha — the first main review of a repository starts there.

## Upgrading sheepdog

Change the sha in `.github/workflows/review.yml` (one line). That change goes through the review like any other; the
new sheepdog version is used for the runs after it lands on the default branch.
