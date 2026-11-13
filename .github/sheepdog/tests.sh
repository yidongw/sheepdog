#!/usr/bin/env bash
# sheepdog's own trusted test list (main's copy; run by the `tests` job of self-review.yml in a checkout of the pushed
# commit on a GitHub-hosted runner): every shell suite, then the reviewer's typecheck and tests, and the check that the
# reviewer runs with no dependencies (node type stripping), actionlint and zizmor — the same checks as ci.yml.
set -euo pipefail
git config --global user.name ci && git config --global user.email ci@example.invalid
echo "::group::shell suites"; bash test/run.sh; echo "::endgroup::"
echo "::group::reviewer: typecheck + tests"
(cd reviewer && npm ci --ignore-scripts --no-audit --no-fund && npx tsc --noEmit && npx vitest run)
echo "::endgroup::"
echo "::group::the reviewer runs with no dependencies"
(cd reviewer && rm -rf node_modules && rc=0 && { node src/review-gate.ts --help || rc=$?; } && test "$rc" -eq 2)
echo "::endgroup::"
# review of 0f5d80c10 #4: the workflow linters are part of the trusted checks, as in ci.yml (same pinned, checksum- and
# hash-verified tools; test/ci/workflow-wiring.sh keeps the two lists equal): merge authority needs them green too.
echo "::group::actionlint 1.7.12 (checksum-verified release binary)"
curl -fsSL -o "$RUNNER_TEMP/al.tgz" https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
echo "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  $RUNNER_TEMP/al.tgz" | sha256sum -c -
tar -xzf "$RUNNER_TEMP/al.tgz" -C "$RUNNER_TEMP" actionlint
"$RUNNER_TEMP/actionlint" -color .github/workflows/*.yml examples/.github/workflows/*.yml
echo "::endgroup::"
echo "::group::zizmor 1.32.0 (hash-pinned wheel)"
python3 -m venv "$RUNNER_TEMP/zz"
echo "zizmor==1.32.0 --hash=sha256:84a6acb975accc13408786a2bd274b572537ca19c933ebbc13e78f3988562071" > "$RUNNER_TEMP/req.txt"
"$RUNNER_TEMP/zz/bin/pip" install -q --require-hashes -r "$RUNNER_TEMP/req.txt"
"$RUNNER_TEMP/zz/bin/zizmor" --offline --min-severity medium .github/workflows examples/.github/workflows
echo "::endgroup::"
