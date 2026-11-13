#!/usr/bin/env python3
"""Stress the actual first-result selectors under the workflow's Bash pipefail mode."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CI = ROOT / "scripts/ci"
failures = []
with tempfile.TemporaryDirectory() as temporary:
    work = Path(temporary)
    # API selectors must retain the first result while draining large producer output.
    (work / "ids").write_text("7\n" + "8\n" * 200000)
    (work / "jobs").write_text('{"jobs":[' + ','.join(
        '{"name":"review","id":%d}' % i for i in range(1000, 21000)) + ']}')
    cases = []
    for line in (CI / "review-passed.sh").read_text().splitlines():
        if line.strip().startswith('art=$(gh api '):
            cases.append((f"artifact selector {len(cases) + 1}", line, "art", "7"))
    assert len(cases) == 2, "approval artifact selectors changed; update the fixture"
    line = next(line for line in (CI / "prior-findings.sh").read_text().splitlines()
                if line.strip().startswith('jid=$(api '))
    cases.append(("ledger job selector", line, "jid", "1000"))
    setup = '''
gh() { cat "$FIXTURE_DIR/ids"; }
api() { cat "$FIXTURE_DIR/jobs"; }
repo=o/r; id=1; rid=1
'''
    env = dict(os.environ, FIXTURE_DIR=str(work), RUNNER_TEMP=str(work))
    for name, line, variable, want in cases:
        script = setup + line.strip() + f'\n[ "${{{variable}}}" = "{want}" ]\n'
        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script, "fixture", "1"],
                                env=env, text=True, capture_output=True)
        if result.returncode:
            failures.append(f"{name}: exit {result.returncode}; {result.stderr.strip()}")
        else:
            print(f"ok: {name} consumes large output and selects the first result")
if failures:
    raise SystemExit("\n".join("FAIL: " + failure for failure in failures))
