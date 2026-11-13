#!/usr/bin/env bash
# gh-cache.sh — fewer GitHub API calls per dispatcher run, without ever answering from an older dispatcher run (sourced
# by review-dispatch.sh; 11-13: eight dispatchers on one token spent ~6000 calls/h against GitHub's 5000/h).
#
#   ghc_init <state dir>   → turns it on for this process and its children: defines gh() and git() (exported, so the
#                            contract scripts the dispatcher runs — review-passed.sh, merge-branch.sh — use them too)
#   ghc_done               → removes this run's memo (the dispatcher's EXIT trap)
#
# Two rules, nothing else (reviews of baf73755e … 8e5891359: every cross-run answer about a run — listings, records,
# workflow pages, jobs, artifacts — was a way to serve the previous attempt of a re-run as approval evidence):
#   1. Per-run memo. GHC_RUN_DIR is a private directory created by ghc_init and removed at exit. Within ONE dispatcher
#      run, identical read requests are answered once: `gh run list …` (keyed by all its arguments except -q) and
#      `gh api <path> [-q <jq>]` for the JSON Actions endpoints (repos/<o>/<r>/actions/runs…, …/actions/workflows/…,
#      keyed by the path; -q is applied locally, as gh prints it). Every answer is GitHub's answer from this run; the next
#      dispatcher run asks again, so a re-run is always seen. Any write — `gh run rerun/cancel/delete`, `gh workflow run`,
#      `gh api` with flags (-X, -f, …), any other gh command, `git push` — wipes the memo before and after it.
#   2. Completed jobs' logs on disk across runs ($STATE/ghcache/logs/<job id>). A re-run creates new job ids, so the log
#      of a job id that has completed never changes. A log is stored only when a jobs answer of THIS run showed that job
#      completed more than two minutes ago. Stored and returned byte for byte (files and redirection only).
# Everything else — artifacts' zips, run log zips, any other endpoint — is the real gh, its output untouched. Without
# GHC_RUN_DIR (a script run outside a dispatcher run) gh() is the real gh. A request the memo cannot store is answered by
# the real gh. Stored logs older than GHC_KEEP_DAYS (2) and abandoned run directories (> 60 min) are removed at ghc_init.

ghc_init() { # ghc_init <state dir>
  GHC_DIR=$1/ghcache
  mkdir -p "$GHC_DIR/logs" || return 1
  find "$GHC_DIR" -mindepth 1 -maxdepth 1 -name 'run.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$GHC_DIR/disk" 2>/dev/null || true   # the cross-run store of the previous design (jobs answers): never read
  find "$GHC_DIR/logs" -type f -mtime +"${GHC_KEEP_DAYS:-2}" -delete 2>/dev/null || true
  GHC_RUN_DIR=$(mktemp -d "$GHC_DIR/run.XXXXXX") || return 1
  export GHC_DIR GHC_RUN_DIR
  export -f gh git ghc_on ghc_wipe ghc_key ghc_out ghc_fetch ghc_api
}
ghc_done() { [ -n "${GHC_RUN_DIR:-}" ] && rm -rf "$GHC_RUN_DIR"; return 0; }

ghc_on() { [ -n "${GHC_RUN_DIR:-}" ] && [ -d "$GHC_RUN_DIR" ] && [ ! -e "$GHC_RUN_DIR.disabled" ]; }
ghc_wipe() {
  [ -n "${GHC_RUN_DIR:-}" ] || return 0
  if ! rm -f "$GHC_RUN_DIR"/m.*; then
    # A sibling marker survives command substitutions and exported child shells.
    # Stop the mutation if even disabling this memo cannot be recorded.
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

gh() {
  ghc_on || { command gh "$@"; return; }
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
    "run view"|"run watch") command gh "$@" ;;   # reads; not memoised
    *) local rc=0; ghc_wipe || return 1; command gh "$@" || rc=$?; ghc_wipe || return 1; return "$rc" ;;   # anything else may write
  esac
}

ghc_api() {
  local q="" p="" f rc=0 id
  local -a orig=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) q=$2; shift 2 ;;
      -*) ghc_wipe || return 1; command gh api "${orig[@]}" || rc=$?; ghc_wipe || return 1; return "$rc" ;;   # -X, -f, -F, --input, …: may write
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
      # a jobs answer: the jobs it shows completed (more than 2 min ago) have final logs
      if [[ "$p" =~ /actions/runs/[0-9]+/jobs ]]; then
        jq -r '.jobs[]? | select(.status == "completed" and (.completed_at // "") != ""
                 and ((.completed_at | sub("\\.[0-9]+"; "") | fromdateiso8601) < now - 120)) | .id' "$f" 2>/dev/null \
          | while read -r id; do : > "$GHC_RUN_DIR/done.$id"; done 2>/dev/null || true
      fi
    fi
    ghc_out "$f" "$q"; return
  fi
  command gh api "${orig[@]}"
}
