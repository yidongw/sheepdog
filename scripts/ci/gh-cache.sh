#!/usr/bin/env bash
# gh-cache.sh — fewer GitHub API calls per dispatcher run (sourced by review-dispatch.sh; 11-13: eight dispatchers on one
# token spent ~6000 calls/h against GitHub's 5000/h: the same run list was fetched ~15 times per run, the jobs and logs of
# the same completed runs every minute).
#
#   ghc_init <cache dir>   → turns the cache on for this process and its children: defines gh() (exported, so the contract
#                            scripts the dispatcher runs — review-passed.sh, merge-branch.sh — use it too)
#
# Deliberately small (reviews of baf73755e … 3408ac406: every extra source of truth was a way to serve a stale attempt).
# What gh() answers without a call — everything else, and every write, is the real gh:
#   · `gh run list -R <repo> [-w <workflow>] [-e <event>] [-b <branch>] -L <n> --json <fields> [-q <jq>]`: ONE listing
#     per filter set (the same server-side -w/-e/-b filters — review_list's trusted filtering is unchanged) with the
#     union of the fields and at least 100 runs, kept GHC_LIST_TTL seconds (60); each call gets its first <n> runs, its
#     fields and its -q. A listing that cannot be made or kept falls back to the caller's own call.
#   · `gh api [-q <jq>] repos/<r>/actions/runs/<id>/jobs`: the run's state is read ONLY from this dispatcher run's
#     listings that are still within GHC_LIST_TTL; when they show the run, all with the same "<status> <updatedAt>", and
#     the status is completed, a jobs answer stored for exactly that state is used (on disk, so later dispatcher runs
#     reuse it), and a fetched answer whose jobs are all completed is stored for it. No listing, listings that
#     disagree, or a run not completed: the real call, nothing stored. A re-run is listed as not completed or with a
#     new updatedAt, so a stored answer of the previous attempt never matches.
#   · `gh api repos/<r>/actions/jobs/<id>/logs`: on disk once a jobs answer of this dispatcher run showed that job
#     completed (a job id belongs to one attempt; its log is final).
#   Never cached: run records, artifacts and attestation zips (approval evidence: they can expire or be deleted without a
#   new attempt), workflow run pages, binary downloads. `gh run cancel` / `rerun` / `delete` drop the kept listings.
#   Cache file names are hashes; writes are best effort — an answer is returned even when it cannot be stored. Disk
#   entries older than GHC_KEEP_DAYS (2) are removed at ghc_init. The cache holds only what the same token read from
#   GitHub, in the dispatcher's private state directory.
GHC_LIST_TTL=${GHC_LIST_TTL:-60}
# (fields every gh since 2.2x knows — no `attempt`: gh 2.45 on the host refuses it; a re-run shows as a new updatedAt)
GHC_FIELDS=databaseId,displayTitle,status,conclusion,headBranch,headSha,workflowName,event,createdAt,updatedAt,number,name

ghc_init() { # ghc_init <dir>
  GHC_DIR=$1
  mkdir -p "$GHC_DIR/disk" || return 1
  find "$GHC_DIR" -mindepth 1 -maxdepth 1 -name 'run.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  find "$GHC_DIR/disk" -type f -mtime +"${GHC_KEEP_DAYS:-2}" -delete 2>/dev/null || true
  GHC_RUN=$(mktemp -d "$GHC_DIR/run.XXXXXX") || return 1
  export GHC_DIR GHC_RUN GHC_LIST_TTL GHC_FIELDS
  export -f gh ghc_fresh ghc_put ghc_key ghc_jq ghc_run_list ghc_run_state ghc_api
}
ghc_done() { [ -n "${GHC_RUN:-}" ] && rm -rf "$GHC_RUN"; return 0; }

ghc_fresh() { # ghc_fresh <file> <max age s> → 0 when the file exists and is younger
  [ -f "$1" ] || return 1
  [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) -lt "$2" ]
}
ghc_put() { # ghc_put <file>  (stdin → file, atomically; best effort)
  local t; t=$(mktemp "$(dirname "$1")/.tmp.XXXXXX" 2>/dev/null) || return 1
  if cat > "$t" 2>/dev/null && mv -f "$t" "$1" 2>/dev/null; then return 0; fi
  rm -f "$t" 2>/dev/null; return 1
}
ghc_key() { printf '%s' "$1" | md5sum | cut -c1-24; }   # a bounded file name for any request
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
  local repo="" wf="" ev="" br="" lim=20 fields="" q="" a="" key f n k
  local -a own
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
  own=(${repo:+-R "$repo"} ${wf:+-w "$wf"} ${ev:+-e "$ev"} ${br:+-b "$br"} -L "$lim" ${fields:+--json "$fields"} ${q:+-q "$q"})
  # only what the union covers is answered here
  [ -n "$fields" ] && [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -le 200 ] || { command gh run list "${own[@]}"; return; }
  for f in ${fields//,/ }; do
    case ",$GHC_FIELDS," in *",$f,"*) ;; *) command gh run list "${own[@]}"; return ;; esac
  done
  key=$GHC_RUN/list.$(ghc_key "$repo|$wf|$ev|$br")
  n=$(( lim > 100 ? lim : 100 ))
  if ghc_fresh "$key" "$GHC_LIST_TTL" && [ "$(cat "$key.n" 2>/dev/null || echo 0)" -ge "$n" ]; then a=$(cat "$key" 2>/dev/null) || a=""; fi
  if [ -z "$a" ]; then
    # a listing this cache cannot make falls back to the caller's own call, uncached
    if ! a=$(command gh run list ${repo:+-R "$repo"} ${wf:+-w "$wf"} ${ev:+-e "$ev"} ${br:+-b "$br"} -L "$n" --json "$GHC_FIELDS" 2>/dev/null) \
       || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$a"; then
      command gh run list "${own[@]}"; return
    fi
    { ghc_put "$key.n" <<<"$n" && ghc_put "$key" <<<"$a"; } || { rm -f "$key" "$key.n" 2>/dev/null || :; }
  fi
  k=$(jq -nc --arg f "$fields" '$f | split(",")')
  jq -c --argjson n "$lim" --argjson k "$k" '[.[:$n][] | with_entries(select(.key as $x | $k | index($x)))]' <<<"$a" | ghc_jq "$q"
}

ghc_run_state() { # ghc_run_state <run id> → "<status> <updatedAt>" when every fresh listing of this run that shows the
  # run agrees on it; "" when none shows it or they disagree (then nothing is answered from the cache)
  local f
  for f in "$GHC_RUN"/list.*; do
    case "$f" in *.n) continue ;; esac
    ghc_fresh "$f" "$GHC_LIST_TTL" || continue
    jq -r --argjson id "$1" '.[]? | select(.databaseId == $id) | "\(.status) \(.updatedAt // "-")"' "$f" 2>/dev/null
  done | sort -u | awk 'NR == 1 { s = $0 } END { if (NR == 1) print s }'
}

ghc_api() {
  local q="" path="" a="" m disk st id
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) q=$2; shift 2 ;;
      -*) command gh api "$@" ${path:+"$path"} ${q:+-q "$q"}; return ;;   # flags this cache does not model: the real call
      *) [ -z "$path" ] || { command gh api "$path" "$@" ${q:+-q "$q"}; return; }; path=$1; shift ;;
    esac
  done
  path=${path#/}; path=${path#https://api.github.com/}
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/runs/([0-9]+)/jobs$ ]]; then
    st=$(ghc_run_state "${BASH_REMATCH[1]}")
    disk=$GHC_DIR/disk/jobs.$(ghc_key "$path|$st")   # stored per run state: another state never matches
    if [ "${st%% *}" = completed ] && [ -f "$disk" ]; then a=$(cat "$disk" 2>/dev/null) || a=""; fi
    if [ -z "$a" ]; then
      a=$(command gh api "$path") || return 1
      if [ "${st%% *}" = completed ] && jq -e '(.jobs | length > 0) and all(.jobs[]; .status == "completed")' >/dev/null 2>&1 <<<"$a"; then
        ghc_put "$disk" <<<"$a" || true
      fi
    fi
    # completed jobs: their logs are final
    jq -r '.jobs[]? | select(.status == "completed") | .id' <<<"$a" 2>/dev/null | while read -r m; do : > "$GHC_RUN/jobdone.$m"; done 2>/dev/null || true
    ghc_jq "$q" <<<"$a"; return
  fi
  if [[ "$path" =~ ^repos/[^/]+/[^/]+/actions/jobs/([0-9]+)/logs$ ]]; then
    id=${BASH_REMATCH[1]}; disk=$GHC_DIR/disk/log.$(ghc_key "$path")
    if [ -f "$disk" ]; then a=$(cat "$disk" 2>/dev/null) || a=""; fi
    if [ -z "$a" ]; then
      a=$(command gh api "$path") || return 1
      if [ -f "$GHC_RUN/jobdone.$id" ]; then ghc_put "$disk" <<<"$a" || true; fi
    fi
    ghc_jq "$q" <<<"$a"; return
  fi
  command gh api "$path" ${q:+-q "$q"}
}
