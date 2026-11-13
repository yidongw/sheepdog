#!/usr/bin/env bash
# gh-cache.sh — fewer GitHub API calls per dispatcher run, never for approval evidence (sourced by review-dispatch.sh;
# 11-13: eight dispatchers on one token spent ~6000 calls/h against GitHub's 5000/h).
#
#   ghc_init <state dir>   → turns it on for this dispatcher run: defines ghm() (this process only) and the write
#                            wrappers gh() / git() (exported, so a write by a child script — merge-branch.sh — counts too)
#   ghc_done               → removes this run's memo (the dispatcher's EXIT trap)
#
# THE SPLIT (reviews of baf73755e … d95e275d3: every cached answer about a run — across runs, then within one run —
# was a way to serve the previous attempt of a re-run as approval evidence):
#   · `gh` is ALWAYS the real gh for reads. Everything that decides pass / land / deploy / complete reads through it:
#     review-passed.sh, merge-branch.sh, review-coverage.sh (review_verdict, review_attestation, …), review-runs.sh, and
#     the dispatcher's own landing / train / devfix / hotfix-complete / verdict checks. ghm is not exported: a child
#     script cannot reach the memo at all (test/ci/gh-cache-memo.sh enforces both).
#   · `ghm` — the per-run memo — only for informational / routing reads in review-dispatch.sh: which runs exist and
#     what is pending (review_list, all_runs_list, the dev CI listing) and notification text (findings, notes,
#     pre-existing findings). Stale by a few seconds at worst, which can delay an action by one dispatcher run, never
#     approve one: every approval re-reads GitHub. Identical reads within ONE dispatcher run are asked once (gh run
#     list keyed by its arguments except -q; gh api on the JSON Actions runs/workflows endpoints keyed by the path, -q
#     applied locally as gh prints it). Any write — gh run rerun/cancel/delete, gh workflow run, gh api with flags,
#     any other gh command, git push — wipes it. The next dispatcher run asks again.
#   · Across runs only the log of a completed job, by job id, read through ghm ($STATE/ghcache/logs/<id>; a re-run makes
#     new job ids, so a completed job's log never changes): stored when a ghm jobs answer of the same run showed the job
#     completed more than two minutes ago; files and redirection only, byte for byte.
# Binary downloads (artifact zips, run log zips) and other endpoints pass through ghm untouched. Without GHC_RUN_DIR
# ghm is the real gh. A request the memo cannot store is answered by the real gh. Stored logs older than GHC_KEEP_DAYS
# (2) and abandoned run directories (> 60 min) are removed at ghc_init.

ghc_init() { # ghc_init <state dir>
  GHC_DIR=$1/ghcache
  mkdir -p "$GHC_DIR/logs" || return 1
  find "$GHC_DIR" -mindepth 1 -maxdepth 1 -name 'run.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$GHC_DIR/disk" 2>/dev/null || true   # the cross-run store of the previous design (jobs answers): never read
  find "$GHC_DIR/logs" -type f -mtime +"${GHC_KEEP_DAYS:-2}" -delete 2>/dev/null || true
  GHC_RUN_DIR=$(mktemp -d "$GHC_DIR/run.XXXXXX") || return 1
  export GHC_DIR GHC_RUN_DIR
  export -f gh git ghc_wipe ghc_on   # the write wrappers only: ghm and its helpers stay in this process
}
ghc_done() { [ -n "${GHC_RUN_DIR:-}" ] && command rm -rf "$GHC_RUN_DIR" "$GHC_RUN_DIR.disabled"; return 0; }

# a wipe that cannot delete the memo disables it for the rest of the run (a sibling marker: seen by subshells and
# children too); when even the marker cannot be written the write itself is not made (review of 43c8601d9 #2, dc21c1e68)
ghc_on() { [ -n "${GHC_RUN_DIR:-}" ] && [ -d "$GHC_RUN_DIR" ] && [ ! -e "$GHC_RUN_DIR.disabled" ]; }
ghc_wipe() {
  [ -n "${GHC_RUN_DIR:-}" ] || return 0
  if ! rm -f "$GHC_RUN_DIR"/m.* 2>/dev/null; then
    printf 'gh-cache: invalidation failed; disabling memo reuse\n' >&2
    : > "$GHC_RUN_DIR.disabled" || return 1
  fi
}
ghc_key() { printf '%s' "$1" | md5sum | cut -c1-32; }
ghc_out() { # ghc_out <file> <jq filter or ""> → the answer as gh prints it (-q: raw strings, compact sorted JSON)
  if [ -n "$2" ]; then jq -rcS "$2" < "$1"; else cat "$1"; fi
}
ghc_fetch() { # ghc_fetch <memo file> <gh args…> → 0 with <memo file> holding the real answer; 1 when gh failed
  # (its stderr shown, nothing kept); 2 when nothing could be written (the caller asks the real gh itself)
  # (written for callers under set -e: every status is taken with ||)
  local f=$1 t rc=0; shift
  t=$(mktemp "$GHC_RUN_DIR/.t.XXXXXX" 2>/dev/null) || return 2
  command gh "$@" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; return 1; fi
  mv -f "$t" "$f" 2>/dev/null || { rm -f "$t"; return 2; }
}

git() {
  case " $* " in
    *" push "*) local rc=0; ghc_wipe || return 1; command git "$@" || rc=$?; ghc_wipe || return 1; return "$rc" ;;
  esac
  command git "$@"
}

gh() { # the real gh; a write wipes the memo
  case "${1:-} ${2:-}" in
    "run list"|"run view"|"run watch") command gh "$@" ;;
    "api "*) local x; for x in "${@:2}"; do
               case "$x" in -q|--jq) ;; -*) local rc=0; ghc_wipe || return 1; command gh "$@" || rc=$?; ghc_wipe || return 1; return "$rc" ;; esac
             done
             command gh "$@" ;;
    *) local rc=0; ghc_wipe || return 1; command gh "$@" || rc=$?; ghc_wipe || return 1; return "$rc" ;;   # anything else may write
  esac
}

ghm() { # the per-run memo: informational / routing reads of review-dispatch.sh only (see the header)
  ghc_on || { gh "$@"; return; }
  case "${1:-} ${2:-}" in
    "run list")
      local -a a=(); local q="" f rc=0
      shift 2
      while [ $# -gt 0 ]; do
        case "$1" in -q|--jq) q=$2; shift 2 ;; *) a+=("$1"); shift ;; esac
      done
      f=$GHC_RUN_DIR/m.$(ghc_key "run list ${a[*]@Q}")
      if [ ! -f "$f" ]; then
        ghc_fetch "$f" run list "${a[@]}" || rc=$?
        [ "$rc" != 1 ] || return 1
        [ "$rc" != 2 ] || { command gh run list "${a[@]}" ${q:+-q "$q"}; return; }
      fi
      ghc_out "$f" "$q" ;;
    "api "*) shift; ghc_api "$@" ;;
    *) gh "$@" ;;
  esac
}

ghc_note_jobs() { # ghc_note_jobs < <jobs answer> — the jobs it shows completed (more than 2 min ago) have final logs:
  # ghm may keep those logs across runs (a jobs answer the dispatcher read itself, through ghm or the real gh)
  ghc_on || { cat > /dev/null; return 0; }
  jq -r '.jobs[]? | select(.status == "completed" and (.completed_at // "") != ""
           and ((.completed_at | sub("\\.[0-9]+"; "") | fromdateiso8601) < now - 120)) | .id' 2>/dev/null \
    | while read -r id; do : > "$GHC_RUN_DIR/done.$id"; done 2>/dev/null || true
  return 0
}

ghc_api() {
  local q="" p="" f rc=0 id
  local -a orig=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) q=$2; shift 2 ;;
      -*) gh api "${orig[@]}"; return ;;   # -X, -f, -F, --input, …: may write (gh wipes)
      *) [ -z "$p" ] || { command gh api "${orig[@]}"; return; }; p=$1; shift ;;
    esac
  done
  p=${p#/}; p=${p#https://api.github.com/}
  if [[ "$p" =~ ^repos/[^/]+/[^/]+/actions/jobs/([0-9]+)/logs$ ]] && [ -z "$q" ]; then
    id=${BASH_REMATCH[1]}
    if [ -f "$GHC_DIR/logs/$id" ]; then cat "$GHC_DIR/logs/$id"; return; fi
    f=$GHC_RUN_DIR/m.$(ghc_key "api $p")
    if [ ! -f "$f" ]; then
      ghc_fetch "$f" api "$p" || rc=$?
      [ "$rc" != 1 ] || return 1
      [ "$rc" != 2 ] || { command gh api "${orig[@]}"; return; }
    fi
    # kept across runs only once a jobs answer of this run showed the job completed (a job id's final log)
    if [ -f "$GHC_RUN_DIR/done.$id" ]; then
      local t; t=$(mktemp "$GHC_DIR/logs/.t.XXXXXX" 2>/dev/null) \
        && { { cp "$f" "$t" && mv -f "$t" "$GHC_DIR/logs/$id"; } 2>/dev/null || rm -f "$t"; }
    fi
    cat "$f"; return
  fi
  # the JSON Actions endpoints about runs and workflows (not logs, not zips: those pass through untouched)
  if [[ "$p" =~ ^repos/[^/]+/[^/]+/actions/(runs|workflows)([/?].*)?$ ]] && ! [[ "$p" =~ /(logs|zip)(\?.*)?$ ]]; then
    f=$GHC_RUN_DIR/m.$(ghc_key "api $p")
    if [ ! -f "$f" ]; then
      ghc_fetch "$f" api "$p" || rc=$?
      [ "$rc" != 1 ] || return 1
      [ "$rc" != 2 ] || { command gh api "${orig[@]}"; return; }
      if [[ "$p" =~ /actions/runs/[0-9]+/jobs ]]; then ghc_note_jobs < "$f"; fi
    fi
    ghc_out "$f" "$q"; return
  fi
  command gh api "${orig[@]}"
}
