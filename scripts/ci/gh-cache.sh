#!/usr/bin/env bash
# gh-cache.sh — fewer GitHub API calls per dispatcher run (sourced by review-dispatch.sh; 11-13: eight dispatchers on one
# token spent ~6000 calls/h against GitHub's 5000/h: the same run list was fetched ~15 times per run, the jobs and logs of
# the same completed runs every minute).
#
#   ghc_init <cache dir>   → turns the cache on for this process and its children: defines gh() (exported, so the contract
#                            scripts the dispatcher runs — review-passed.sh, merge-branch.sh — use it too)
#
# What gh() answers without a call (everything else, and every write, goes to the real gh):
#   · `gh run list -R <repo> [-w <workflow>] [-e <event>] [-b <branch>] -L <n> --json <fields> [-q <jq>]`: ONE listing
#     per filter set (same server-side -w/-e/-b filters — review_list's trusted filtering is unchanged) with the union of
#     the fields and at least 100 runs, kept GHC_LIST_TTL seconds (60); each call gets its first <n> runs, its fields,
#     its -q. `gh run cancel` / `rerun` / `delete` drop the listings (the next call lists again).
#   · `gh api [-q <jq>] <path>` (a GET without other flags) for
#       repos/<r>/actions/runs/<id>, …/runs/<id>/jobs, …/runs/<id>/artifacts — kept for this run (GHC_LIST_TTL), and on
#           disk once the run is COMPLETED according to a listing of this run (status completed, its updatedAt recorded):
#           such a run's record no longer changes. A disk entry is used while a listing shows the run completed with that
#           same updatedAt (a re-run is listed as not completed / with a new updatedAt → fetched again); for a
#           run no listing shows (older than the listings) for at most GHC_UNLISTED_TTL seconds (3600) after it was stored;
#       repos/<r>/actions/jobs/<id>/logs — on disk once a jobs answer showed that job completed (a job id belongs to one
#           attempt; its log is final);
#       repos/<r>/actions/artifacts/<id>/zip — on disk (an artifact never changes);
#       anything else under repos/<r>/actions/ (e.g. a workflow's run pages) — kept for this run only (GHC_LIST_TTL).
#   Failures are never cached. Disk entries older than GHC_KEEP_DAYS (2) are removed at ghc_init.
# The cache holds only what the same token read from GitHub; it lives in the dispatcher's private state directory.
GHC_LIST_TTL=${GHC_LIST_TTL:-60}
GHC_UNLISTED_TTL=${GHC_UNLISTED_TTL:-3600}
# (fields every gh since 2.2x knows — no `attempt`: gh 2.4x on the host refuses it; a re-run shows as a new updatedAt)
GHC_FIELDS=databaseId,displayTitle,status,conclusion,headBranch,headSha,workflowName,event,createdAt,updatedAt,number,name

ghc_init() { # ghc_init <dir>
  GHC_DIR=$1
  mkdir -p "$GHC_DIR/disk" || return 1
  find "$GHC_DIR" -mindepth 1 -maxdepth 1 -name 'run.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  find "$GHC_DIR/disk" -type f -mtime +"${GHC_KEEP_DAYS:-2}" -delete 2>/dev/null || true
  GHC_RUN=$(mktemp -d "$GHC_DIR/run.XXXXXX") || return 1
  export GHC_DIR GHC_RUN GHC_LIST_TTL GHC_UNLISTED_TTL GHC_FIELDS
  export -f gh ghc_fresh ghc_put ghc_run_list ghc_api ghc_run_state ghc_jq
}
ghc_done() { [ -n "${GHC_RUN:-}" ] && rm -rf "$GHC_RUN"; return 0; }

ghc_fresh() { # ghc_fresh <file> <max age s> → 0 when the file exists and is younger
  [ -f "$1" ] || return 1
  [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) -lt "$2" ]
}
ghc_put() { # ghc_put <file>  (stdin → file, atomically)
  local t; t=$(mktemp "$(dirname "$1")/.tmp.XXXXXX") || return 1
  cat > "$t" && mv -f "$t" "$1"
}
ghc_jq() { # ghc_jq <jq filter or ""> < json → the answer as gh prints it (-q: raw strings)
  if [ -n "$1" ]; then jq -r "$1"; else cat; fi
}

gh() {
  if [ -z "${GHC_RUN:-}" ] || [ ! -d "$GHC_RUN" ]; then command gh "$@"; return; fi
  case "${1:-} ${2:-}" in
    "run list") shift 2; ghc_run_list "$@" ;;
    "run cancel"|"run rerun"|"run delete") rm -f "$GHC_RUN"/list.* 2>/dev/null; command gh "$@" ;;
    "api "*) shift; ghc_api "$@" ;;
    *) command gh "$@" ;;
  esac
}

ghc_run_list() {
  local repo="" wf="" ev="" br="" lim=20 fields="" q="" a key f n k
  while [ $# -gt 0 ]; do
    case "$1" in
      -R|--repo) repo=$2; shift 2 ;;
      -w|--workflow) wf=$2; shift 2 ;;
      -e|--event) ev=$2; shift 2 ;;
      -b|--branch) br=$2; shift 2 ;;
      -L|--limit) lim=$2; shift 2 ;;
      --json) fields=$2; shift 2 ;;
      -q|--jq) q=$2; shift 2 ;;
      *) command gh run list ${repo:+-R "$repo"} ${wf:+-w "$wf"} ${ev:+-e "$ev"} ${br:+-b "$br"} -L "$lim" ${fields:+--json "$fields"} ${q:+-q "$q"} "$@"; return ;;
    esac
  done
  # only what the union covers is answered here
  [ -n "$fields" ] && [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -le 200 ] || { command gh run list ${repo:+-R "$repo"} ${wf:+-w "$wf"} ${ev:+-e "$ev"} ${br:+-b "$br"} -L "$lim" ${fields:+--json "$fields"} ${q:+-q "$q"}; return; }
  for f in ${fields//,/ }; do
    case ",$GHC_FIELDS," in *",$f,"*) ;; *) command gh run list ${repo:+-R "$repo"} ${wf:+-w "$wf"} ${ev:+-e "$ev"} ${br:+-b "$br"} -L "$lim" --json "$fields" ${q:+-q "$q"}; return ;; esac
  done
  key=$(printf '%s\n' "$repo|$wf|$ev|$br" | md5sum | cut -c1-16)
  n=$(( lim > 100 ? lim : 100 ))
  if ! ghc_fresh "$GHC_RUN/list.$key" "$GHC_LIST_TTL" || [ "$(cat "$GHC_RUN/list.$key.n" 2>/dev/null || echo 0)" -lt "$n" ]; then
    # a listing this cache cannot make (whatever the reason) falls back to the caller's own call, uncached
    if ! a=$(command gh run list ${repo:+-R "$repo"} ${wf:+-w "$wf"} ${ev:+-e "$ev"} ${br:+-b "$br"} -L "$n" --json "$GHC_FIELDS" 2>/dev/null) \
       || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$a"; then
      command gh run list ${repo:+-R "$repo"} ${wf:+-w "$wf"} ${ev:+-e "$ev"} ${br:+-b "$br"} -L "$lim" --json "$fields" ${q:+-q "$q"}; return
    fi
    ghc_put "$GHC_RUN/list.$key" <<<"$a" && echo "$n" > "$GHC_RUN/list.$key.n"
  fi
  k=$(jq -nc --arg f "$fields" '$f | split(",")')
  jq -c --argjson n "$lim" --argjson k "$k" '[.[:$n][] | with_entries(select(.key as $x | $k | index($x)))]' "$GHC_RUN/list.$key" | ghc_jq "$q"
}

ghc_run_state() { # ghc_run_state <run id> → "<status> <updatedAt>" from this run's listings ("" when none lists it)
  local f
  for f in "$GHC_RUN"/list.*; do
    case "$f" in *.n) continue ;; esac
    [ -f "$f" ] || continue
    jq -r --argjson id "$1" 'first(.[] | select(.databaseId == $id) | "\(.status) \(.updatedAt // "-")") // empty' "$f" 2>/dev/null | head -1 | grep . && return 0
  done
  return 0
}

ghc_api() {
  local q="" path="" a m disk memo st att key
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) q=$2; shift 2 ;;
      -*) command gh api "$@" ${path:+"$path"} ${q:+-q "$q"}; return ;;   # flags this cache does not model: the real call
      *) [ -z "$path" ] || { command gh api "$path" "$@" ${q:+-q "$q"}; return; }; path=$1; shift ;;
    esac
  done
  path=${path#/}; path=${path#https://api.github.com/}
  key=$(printf '%s' "$path" | tr -c 'A-Za-z0-9._-' '_')
  memo=$GHC_RUN/api.$key
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/runs/([0-9]+)(/jobs|/artifacts)?$ ]]; then
    disk=$GHC_DIR/disk/$key; st=$(ghc_run_state "${BASH_REMATCH[1]}")
    if ghc_fresh "$memo" "$GHC_LIST_TTL"; then a=$(cat "$memo")
    elif [ -f "$disk" ] && { att=$(cat "$disk.version" 2>/dev/null || echo x)
           { [ -n "$st" ] && [ "$st" = "completed $att" ]; } || { [ -z "$st" ] && ghc_fresh "$disk" "$GHC_UNLISTED_TTL"; }; }; then
      a=$(cat "$disk")
    else
      a=$(command gh api "$path") || return 1
      ghc_put "$memo" <<<"$a"
      # on disk only what is final: the listing says completed, and the answer is completed too (a re-run between the
      # listing and this call answers for the new attempt: not completed)
      if [ "${st%% *}" = completed ] && jq -e '
           if has("jobs") then (.jobs | length > 0) and all(.jobs[]; .status == "completed")
           elif has("artifacts") then true
           else .status == "completed" end' >/dev/null 2>&1 <<<"$a"; then
        ghc_put "$disk" <<<"$a" && echo "${st#* }" > "$disk.version"
      fi
    fi
    if [[ "$path" =~ /jobs$ ]]; then   # completed jobs: their logs are final
      jq -r '.jobs[]? | select(.status == "completed") | .id' <<<"$a" 2>/dev/null | while read -r m; do : > "$GHC_RUN/jobdone.$m"; done
    fi
    ghc_jq "$q" <<<"$a"; return
  fi
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/jobs/([0-9]+)/logs$ ]]; then
    disk=$GHC_DIR/disk/$key
    if [ -f "$disk" ]; then ghc_jq "$q" < "$disk"; return; fi
    if [ -f "$GHC_RUN/jobdone.${BASH_REMATCH[1]}" ]; then
      command gh api "$path" > "$disk.tmp" || { rm -f "$disk.tmp"; return 1; }
      mv -f "$disk.tmp" "$disk"; ghc_jq "$q" < "$disk"; return
    fi
    command gh api "$path" ${q:+-q "$q"}; return
  fi
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/artifacts/[0-9]+/zip$ ]]; then
    disk=$GHC_DIR/disk/$key
    if [ ! -f "$disk" ]; then
      command gh api "$path" > "$disk.tmp" || { rm -f "$disk.tmp"; return 1; }
      mv -f "$disk.tmp" "$disk"
    fi
    cat "$disk"; return
  fi
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/ ]]; then
    if ! ghc_fresh "$memo" "$GHC_LIST_TTL"; then
      a=$(command gh api "$path") || return 1
      ghc_put "$memo" <<<"$a"
    fi
    ghc_jq "$q" < "$memo"; return
  fi
  command gh api "$path" ${q:+-q "$q"}
}
