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
#   · `gh api [-q <jq>] <path>` (a GET without other flags):
#       repos/<r>/actions/runs/<id>, …/runs/<id>/jobs — the run's state is "<status> <updatedAt>" from the NEWEST listing
#           of this dispatcher run that shows it and is still within GHC_LIST_TTL (a run no fresh listing shows: its
#           record runs/<id>, one call per run). An
#           answer kept for this run (GHC_LIST_TTL) is used only while that state is the one it was fetched under; a
#           jobs answer goes on disk once the state is completed and every job in it is completed, and is used while
#           the state is "completed <the same updatedAt>" (a re-run is listed as not completed / with a new updatedAt);
#       repos/<r>/actions/runs/<id>/artifacts — kept for this run only (GHC_LIST_TTL): an artifact can expire or be
#           deleted without a new attempt, so its presence is always read fresh (review of baf73755e #4);
#       repos/<r>/actions/artifacts/<id>/zip — on disk (an artifact's content never changes), but answered from disk only
#           when this dispatcher run's artifacts listing showed that artifact unexpired;
#       repos/<r>/actions/jobs/<id>/logs — on disk once a jobs answer showed that job completed (a job id belongs to one
#           attempt; its log is final);
#       repos/<r>/actions/workflows/<wf>/runs?… (review-runs.sh's pages) — kept for this run only (GHC_LIST_TTL);
#       nothing else (binary downloads such as a run's log zip go to the real gh untouched).
#   `gh run cancel` / `rerun` / `delete` drop every listing and answer kept for this run. Cache files are named by a
#   hash of the request; a failed answer is never cached, and an answer that cannot be written is still returned.
#   Disk entries older than GHC_KEEP_DAYS (2) are removed at ghc_init.
# The cache holds only what the same token read from GitHub; it lives in the dispatcher's private state directory.
GHC_LIST_TTL=${GHC_LIST_TTL:-60}
# (fields every gh since 2.2x knows — no `attempt`: gh 2.4x on the host refuses it; a re-run shows as a new updatedAt)
GHC_FIELDS=databaseId,displayTitle,status,conclusion,headBranch,headSha,workflowName,event,createdAt,updatedAt,number,name

ghc_init() { # ghc_init <dir>
  GHC_DIR=$1
  mkdir -p "$GHC_DIR/disk" || return 1
  find "$GHC_DIR" -mindepth 1 -maxdepth 1 -name 'run.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  find "$GHC_DIR/disk" -type f -mtime +"${GHC_KEEP_DAYS:-2}" -delete 2>/dev/null || true
  GHC_RUN=$(mktemp -d "$GHC_DIR/run.XXXXXX") || return 1
  export GHC_DIR GHC_RUN GHC_LIST_TTL GHC_FIELDS
  export -f gh ghc_fresh ghc_put ghc_key ghc_run_list ghc_api ghc_run_state ghc_jq
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
ghc_key() { printf '%s' "$1" | md5sum | cut -c1-24; }   # a bounded file name for any request (review of baf73755e #5)
ghc_jq() { # ghc_jq <jq filter or ""> < json → the answer as gh prints it (-q: raw strings)
  if [ -n "$1" ]; then jq -r "$1"; else cat; fi
}

gh() {
  if [ -z "${GHC_RUN:-}" ] || [ ! -d "$GHC_RUN" ]; then command gh "$@"; return; fi
  case "${1:-} ${2:-}" in
    "run list") shift 2; ghc_run_list "$@" ;;
    "run cancel"|"run rerun"|"run delete") rm -f "$GHC_RUN"/list.* "$GHC_RUN"/api.* 2>/dev/null; command gh "$@" ;;
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
  key=$(ghc_key "$repo|$wf|$ev|$br")
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

ghc_run_state() { # ghc_run_state <run id> → "<status> <updatedAt>" from the NEWEST fresh listing of this run that shows it ("" when none)
  local f
  # newest first (review of baf73755e #3: an older listing must not override a newer one that saw a re-run)
  while IFS= read -r f; do   # our own hashed file names: no blanks
    case "$f" in *.n) continue ;; esac
    ghc_fresh "$f" "$GHC_LIST_TTL" || continue   # a listing past its 60 s says nothing (review of 879c8c521 #3)
    jq -r --argjson id "$1" 'first(.[] | select(.databaseId == $id) | "\(.status) \(.updatedAt // "-")") // empty' "$f" 2>/dev/null | head -1 | grep . && return 0
  done < <(ls -t "$GHC_RUN"/list.* 2>/dev/null)
  return 0
}

ghc_api() {
  local q="" path="" a m disk memo st key rec sub id tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) q=$2; shift 2 ;;
      -*) command gh api "$@" ${path:+"$path"} ${q:+-q "$q"}; return ;;   # flags this cache does not model: the real call
      *) [ -z "$path" ] || { command gh api "$path" "$@" ${q:+-q "$q"}; return; }; path=$1; shift ;;
    esac
  done
  path=${path#/}; path=${path#https://api.github.com/}
  key=$(ghc_key "$path"); memo=$GHC_RUN/api.$key; disk=$GHC_DIR/disk/$key
  if [[ "$path" =~ ^(repos/[^/]+/[^/]+/actions/runs/([0-9]+))(/jobs)?$ ]]; then
    rec=${BASH_REMATCH[1]} id=${BASH_REMATCH[2]} sub=${BASH_REMATCH[3]}
    st=$(ghc_run_state "$id")
    # a run no listing shows: for its jobs, the record (one call, kept for this run) gives the state
    if [ -z "$st" ] && [ -n "$sub" ]; then st=$(ghc_api "$rec" -q '"\(.status) \(.updated_at)"' 2>/dev/null) || st=""; fi
    if ghc_fresh "$memo" "$GHC_LIST_TTL" && [ "$(cat "$memo.st" 2>/dev/null)" = "$st" ]; then a=$(cat "$memo")
    elif [ -n "$sub" ] && [ -f "$disk" ] && [ "${st%% *}" = completed ] && [ "$st" = "completed $(cat "$disk.version" 2>/dev/null)" ]; then a=$(cat "$disk")
    else
      a=$(command gh api "$path") || return 1
      { ghc_put "$memo" <<<"$a" && printf '%s' "$st" > "$memo.st"; } 2>/dev/null || true
      # on disk only a final jobs answer: the state is completed and so is every job in the answer (a re-run between
      # the listing and this call answers for the new attempt: not completed)
      if [ -n "$sub" ] && [ "${st%% *}" = completed ] \
         && jq -e '(.jobs | length > 0) and all(.jobs[]; .status == "completed")' >/dev/null 2>&1 <<<"$a"; then
        { ghc_put "$disk" <<<"$a" && printf '%s' "${st#* }" > "$disk.version"; } 2>/dev/null || true
      fi
    fi
    if [ -n "$sub" ]; then   # completed jobs: their logs are final
      jq -r '.jobs[]? | select(.status == "completed") | .id' <<<"$a" 2>/dev/null | while read -r m; do : > "$GHC_RUN/jobdone.$m"; done 2>/dev/null || true
    fi
    ghc_jq "$q" <<<"$a"; return
  fi
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/runs/[0-9]+/artifacts$ ]]; then
    if ghc_fresh "$memo" "$GHC_LIST_TTL"; then a=$(cat "$memo")
    else a=$(command gh api "$path") || return 1; ghc_put "$memo" <<<"$a" 2>/dev/null || true; fi
    # the artifacts this run saw unexpired: only their zips may be answered from disk
    jq -r '.artifacts[]? | select(.expired != true) | .id' <<<"$a" 2>/dev/null | while read -r m; do : > "$GHC_RUN/artok.$m"; done 2>/dev/null || true
    ghc_jq "$q" <<<"$a"; return
  fi
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/artifacts/([0-9]+)/zip$ ]]; then
    id=${BASH_REMATCH[1]}
    if [ -f "$disk" ] && [ -f "$GHC_RUN/artok.$id" ]; then cat "$disk"; return; fi
    tmp=$(mktemp "$GHC_RUN/.zip.XXXXXX" 2>/dev/null) || { command gh api "$path"; return; }
    if ! command gh api "$path" > "$tmp"; then rm -f "$tmp"; return 1; fi
    cat "$tmp"; mv -f "$tmp" "$disk" 2>/dev/null || rm -f "$tmp"
    return 0
  fi
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/jobs/([0-9]+)/logs$ ]]; then
    id=${BASH_REMATCH[1]}
    if [ -f "$disk" ]; then ghc_jq "$q" < "$disk"; return; fi
    a=$(command gh api "$path") || return 1
    if [ -f "$GHC_RUN/jobdone.$id" ]; then ghc_put "$disk" <<<"$a" 2>/dev/null || true; fi
    ghc_jq "$q" <<<"$a"; return
  fi
  # a workflow's run pages (review-runs.sh) — JSON; every other endpoint (binary run-log zips, …) goes to the real gh
  # (review of afb14f77d #4)
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/workflows/[^/?]+/runs(\?.*)?$ ]]; then
    if ghc_fresh "$memo" "$GHC_LIST_TTL"; then a=$(cat "$memo")
    else a=$(command gh api "$path") || return 1; ghc_put "$memo" <<<"$a" 2>/dev/null || true; fi
    ghc_jq "$q" <<<"$a"; return
  fi
  command gh api "$path" ${q:+-q "$q"}
}
