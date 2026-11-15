# Shared offline Git/GitHub fixture for the canonical reader and dispatcher regressions.
# Caller sets ROOT and fail(); all API responses and temporary histories stay under T.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$RANDOM $2" >> "$T/src/$1"; g add "$1"; g commit -q -m "$2" ${3:+-m "$3"}; g rev-parse HEAD; }
P=$(c f production)
g update-ref refs/remotes/origin/main "$P"
g checkout -q -b dev
A=$(c a "A")
X=$(c x "X (its review blocked)")
N=$(c n "N")
F=$(c x "F: repair of X" "Review-Fix-Of: $X")

# fake GitHub API: $T/api/list (the run listing), <id>.jobs (latest attempt), <id>.a<k>.jobs (earlier attempts),
# <job id>.log, <id>.zip (the run's attestation)
mkdir -p "$T/bin" "$T/api"
reset() { : > "$T/api/list"; rm -f "$T/api/"*.jobs "$T/api/"*.zip "$T/api/"*.log "$T/api/"*.nozip "$T/api/"*.arts; }
# listing <id> <title> [<run_attempt>] [<status>] [<conclusion>]
listing() {
  printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"%s","status":"%s","conclusion":%s,"event":"workflow_run","head_branch":"main","run_attempt":%s}\n' \
    "$1" "$2" "${4:-completed}" "$([ "${4:-completed}" = completed ] && echo "\"${5:-success}\"" || echo null)" "${3:-1}" >> "$T/api/list"
}
# attempt <id> <k> <latest k> <step: success|failure|skipped|crash|cancelled|running> [<tests conclusion>]
attempt() {
  local id=$1 k=$2 n=$3 st=$4 jid=$(( $1 * 10 + $2 )) js=completed jc sc f
  case "$st" in
    success|skipped) jc=success; sc=$st ;;
    failure) jc=failure; sc=failure ;;
    crash) jc=failure; sc=failure ;;
    cancelled) jc=cancelled; sc=cancelled ;;
    running) js=in_progress; jc=; sc= ;;
  esac
  f=$T/api/$id.jobs; [ "$k" = "$n" ] || f=$T/api/$id.a$k.jobs
  printf '{"jobs":[{"name":"tests","run_attempt":%s,"status":"completed","conclusion":"%s","steps":[]},{"name":"review","id":%s,"run_attempt":%s,"status":"%s","conclusion":%s,"completed_at":"2026-11-15T12:00:00Z","steps":[{"name":"Review (blocking)","conclusion":%s}]}]}\n' \
    "$k" "${5:-success}" "$jid" "$k" "$js" "$([ -n "$jc" ] && echo "\"$jc\"" || echo null)" "$([ -n "$sc" ] && echo "\"$sc\"" || echo null)" > "$f"
  { echo "2026-11-15T00:00:01.0Z review-gate: reviewing run $id attempt $k"
    [ "$st" = failure ] && echo "2026-11-15T00:00:02.0Z review-gate: BLOCKED #1 regression [should]: finding of run $id attempt $k"
    [ "$st" = crash ] && echo "2026-11-15T00:00:02.0Z review-gate: reviewer failed: crashed"; true; } > "$T/api/$jid.log"
}
# att <id> <head> <base> [<kind>] [<attempt>]: review.yml's per-attempt artifact "review-attestation-<attempt>" (run_id /
# run_attempt inside; artifact id <id>*100+<attempt>); without <attempt> the legacy run-wide "review-attestation" (id <id>)
att() {
  local aid=$1 name=review-attestation
  [ -z "${5:-}" ] || { aid=$(( $1 * 100 + $5 )); name=review-attestation-$5; }
  jq -nc --arg h "$2" --arg b "$3" --arg k "${4:-review}" --arg m "$P" --arg rid "$1" --arg ra "${5:-}" \
    '{head: $h, base: $b, kind: $k, main: $m} + (if $ra == "" then {} else {run_id: $rid, run_attempt: $ra} end)' > "$T/api/att.json"
  python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"review-attestation.json"); z.close()' "$T/api/$aid.zip" "$T/api/att.json"
  printf '{"name":"%s","id":%s}\n' "$name" "$aid" >> "$T/api/$1.arts"
}
# a one-attempt completed run with its attestation: run1 <id> <title> <step> <attested base> [<kind>]
run1() {
  local k=review; [ "$3" = skipped ] && k=tests-only-fix
  listing "$1" "$2" 1 completed "$([ "$3" = success ] || [ "$3" = skipped ] && echo success || echo failure)"
  attempt "$1" 1 1 "$3"; att "$1" "${2#* }" "$4" "${5:-$k}"
}
cat > "$T/bin/page" <<PAGE
#!/usr/bin/env bash
p=\$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"\$1"); p=\${p:-1}
st=\$(sed -nE 's/.*[?&]status=([a-z]+).*/\1/p' <<<"\$1")
sed -n "\$(( (p - 1) * 100 + 1 )),\$(( p * 100 ))p" "$T/api/list" | jq -s --arg st "\$st" '{workflow_runs: [.[] | select(\$st == "" or (\$st == "completed" and .status == "completed") or .conclusion == \$st)]}'
PAGE
cat > "$T/bin/answer" <<ANS
#!/usr/bin/env bash
u=\${1#*repos/o/r/}
case "\$u" in
  *workflows/review.yml/runs*) "$T/bin/page" "\$u" ;;
  actions/runs/*/attempts/*/jobs) id=\${u#actions/runs/}; k=\${id#*/attempts/}; id=\${id%%/*}; cat "$T/api/\$id.a\${k%%/*}.jobs" 2>/dev/null || exit 22 ;;
  actions/runs/*/jobs) id=\${u#actions/runs/}; cat "$T/api/\${id%%/*}.jobs" 2>/dev/null || exit 22 ;;
  actions/jobs/*/logs) id=\${u%/logs}; cat "$T/api/\${id##*/}.log" 2>/dev/null || exit 22 ;;
  actions/runs/*/artifacts) id=\${u#actions/runs/}; id=\${id%%/*}; cat "$T/api/\$id.arts" 2>/dev/null | jq -s '{artifacts: .}' ;;
  actions/artifacts/*/zip) id=\${u%/zip}; [ ! -e "$T/api/\${id##*/}.nozip" ] || exit 22; cat "$T/api/\${id##*/}.zip" ;;
  *) exit 22 ;;
esac
ANS
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
"$T/bin/answer" "\${@: -1}"
CURL
cat > "$T/bin/gh" <<GH
#!/usr/bin/env bash
[ "\$1" = api ] || exit 1
q=""; [ "\${3:-}" = -q ] && q=\$4
case "\$2" in */zip|*/logs) exec "$T/bin/answer" "\$2" ;; esac
j=\$("$T/bin/answer" "\$2") || exit 1
if [ -n "\$q" ]; then jq -r "\$q" <<<"\$j"; else printf '%s\n' "\$j"; fi
GH
chmod +x "$T/bin/"*
env_() { (cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r "$@"); }
# the shared reader itself: verdict <sha> <mode> → "<kind> <run> <attempt>" | "unknown <run> <attempt>" | "none"
verdict() {
  env_ bash -c '. "$1/scripts/ci/review-runs.sh"; review_api() { gh api "repos/o/r/$1"; }; . "$1/scripts/ci/review-coverage.sh"
    rc=0; review_first_verdict_line "$2" "$3" || rc=$?; [ "$rc" != 1 ] || echo none' _ "$ROOT" "$1" "$2" 2>/dev/null
}
rp() { env_ bash "$ROOT/scripts/ci/review-passed.sh" "$@" >/dev/null 2>&1; }
expect() { local got; got=$(verdict "$1" "$2"); [ "$got" = "$3" ] || fail "$4: the verdict of ${1:0:7} ($2) is '$got', expected '$3'"; }
# the dev chain: A passed (11), X blocked (12), N passed (13); F is the tests-only round over N (repairs X)
chain() { run1 11 "review $A" success "$P"; run1 12 "review $X" failure "$A"; run1 13 "review $N" success "$X"; }

