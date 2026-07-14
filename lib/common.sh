#!/usr/bin/env bash
# Shared helpers for gh-runner-toggle (grt). Sourced by every bin/grt-* script.
#
# The tool makes a private repo's CI fall back from GitHub-hosted runners to a
# free self-hosted Docker runner on this PC, driven by a single per-repo
# `RUNNER` Actions variable. See spec.md / README.md.

set -euo pipefail

# --- paths -------------------------------------------------------------------
# This file lives in lib/, so the repo root is one level up.
GRT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRT_ROOT="$(cd "$GRT_LIB_DIR/.." && pwd)"
# shellcheck disable=SC2034  # used by the bin/grt-install-* scripts that source this file
GRT_BIN_DIR="$GRT_ROOT/bin"
GRT_STATE_DIR="$GRT_ROOT/.state"
GRT_REPOS_FILE="$GRT_ROOT/repos.txt"

# --- tunables (override via environment) ------------------------------------
GRT_IMAGE="${GRT_IMAGE:-myoung34/github-runner:latest}"
GRT_LABEL="${GRT_LABEL:-self-hosted}"
GRT_QUOTA="${GRT_QUOTA:-2000}"    # included Actions minutes/month (free plan)
GRT_MARGIN="${GRT_MARGIN:-100}"   # flip to self-hosted when remaining < this
# Per-container resource caps so busy runners can't saturate the PC while it's
# in use. Set to "" to uncap.
GRT_CPUS="${GRT_CPUS:-4}"
GRT_MEMORY="${GRT_MEMORY:-6g}"
# Re-pull the runner image when the local copy is older than this. GitHub
# force-retires old runner clients, so a never-refreshed image is a time bomb:
# everything looks online while every job fails "runner version too old".
# (Containers also self-update between restarts; this keeps fresh starts near
# current so they don't spend their first minutes updating.)
GRT_IMAGE_MAX_AGE_DAYS="${GRT_IMAGE_MAX_AGE_DAYS:-7}"

# --- logging -----------------------------------------------------------------
grt_log() { echo "[$(date '+%H:%M:%S')] $*"; }
grt_die() { echo "error: $*" >&2; exit 1; }

# Keep an append-only log from growing forever. Truncates IN PLACE (cat >, not
# mv) because the caller's own stdout may hold an O_APPEND fd on this file —
# replacing the inode would silently divert subsequent writes.
grt_rotate_log() {
  local f="$1" max=$((512 * 1024)) size
  [ -f "$f" ] || return 0
  size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  [ "$size" -gt "$max" ] || return 0
  tail -n 200 "$f" > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
}

# --- desktop notification (best-effort, Windows toast) ------------------------
# Auto-flip silently redirecting ALL CI to (or away from) this PC is worth a
# heads-up. No single quotes in the arguments.
grt_notify() {
  local title="$1" body="$2"
  command -v powershell.exe >/dev/null 2>&1 || return 0
  MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command "
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null;
    \$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);
    \$t = \$x.GetElementsByTagName('text');
    \$t.Item(0).AppendChild(\$x.CreateTextNode('$title')) | Out-Null;
    \$t.Item(1).AppendChild(\$x.CreateTextNode('$body')) | Out-Null;
    \$appid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe';
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(\$appid).Show([Windows.UI.Notifications.ToastNotification]::new(\$x));
  " >/dev/null 2>&1 || true
}

# --- gh wrapper --------------------------------------------------------------
# Git Bash rewrites leading-slash API paths (e.g. /users/...) into Windows
# paths, which breaks `gh api`. MSYS_NO_PATHCONV=1 disables that mangling.
gh_api() { MSYS_NO_PATHCONV=1 gh api "$@"; }

# --- authenticated user (cached) --------------------------------------------
grt_user() {
  if [ -z "${GRT_USER:-}" ]; then
    GRT_USER="$(gh_api user --jq .login)" || grt_die "gh not authenticated (run: gh auth status)"
  fi
  printf '%s' "$GRT_USER"
}

# --- repo list ---------------------------------------------------------------
# All covered repos from repos.txt, skipping blank lines and # comments.
# Line format: "owner/name [count]" — count = how many runner instances to run
# for that repo (default 1). Two instances let a workflow's parallel jobs
# actually run in parallel instead of queueing on a single runner.
grt_all_repos() {
  [ -f "$GRT_REPOS_FILE" ] || return 0
  sed -E 's/#.*$//' "$GRT_REPOS_FILE" | awk 'NF { print $1 }'
}

# Instance count for a repo: the optional second column in repos.txt.
grt_repo_count() {
  local n=""
  if [ -f "$GRT_REPOS_FILE" ]; then
    n="$(sed -E 's/#.*$//' "$GRT_REPOS_FILE" | awk -v r="$1" '$1==r { print $2; exit }')"
  fi
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -ge 1 ] || n=1
  printf '%s' "$n"
}

# Which repos a command acts on: its args if any, else every covered repo.
grt_resolve_repos() {
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else grt_all_repos; fi
}

# --- naming ------------------------------------------------------------------
# Runners are named after THIS MACHINE (sam-pc-1, sam-pc-2, …), not the repo: a
# registration is already scoped to one repo, so the name's job is to say WHERE
# the runner lives. Containers stay repo-prefixed (night-in-runner-1) because
# the local Docker namespace is shared across every covered repo.
grt_repo_slug()   { printf '%s' "${1##*/}"; }             # owner/name -> name
grt_machine_name() {
  if [ -n "${GRT_RUNNER_BASENAME:-}" ]; then printf '%s' "$GRT_RUNNER_BASENAME"; return; fi
  hostname | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-'
}
grt_container_name() { printf '%s-runner-%s' "$(grt_repo_slug "$1")" "$2"; }  # <repo> <index>
grt_runner_name()    { printf '%s-%s' "$(grt_machine_name)" "$1"; }           # <index>
# Pre-multi-instance names ("<repo>-runner" / "<repo>-pc"), swept during
# start/stop so an upgrade cleanly replaces them.
grt_legacy_container_name() { printf '%s-runner' "$(grt_repo_slug "$1")"; }
grt_legacy_runner_name()    { printf '%s-pc' "$(grt_repo_slug "$1")"; }

# --- RUNNER variable (the "mode") -------------------------------------------
# NB: `gh api` prints the error BODY (JSON) to stdout on a 404, so the output
# is only trustworthy when the call succeeds — discard it otherwise.
grt_get_mode() {
  local v
  v="$(gh_api "repos/$1/actions/variables/RUNNER" --jq .value 2>/dev/null)" || v=""
  printf '%s' "$v"
}
grt_set_mode() { gh variable set RUNNER --repo "$1" --body "$2" >/dev/null; }

# --- state markers -----------------------------------------------------------
grt_state_init() { mkdir -p "$GRT_STATE_DIR"; }
grt_hold_file()  { printf '%s/hold' "$GRT_STATE_DIR"; }
# hold contains the billing month (YYYY-MM) it was set in; auto-expires when the
# month rolls over so automatic control resumes on a fresh cycle.
grt_set_hold()   { grt_state_init; date +%Y-%m > "$(grt_hold_file)"; }
grt_clear_hold() { rm -f "$(grt_hold_file)"; }

# --- Docker ------------------------------------------------------------------
grt_wait_for_docker() {
  docker info >/dev/null 2>&1 && return 0
  grt_log "waiting for Docker (up to ~3 min)…"
  local i
  for i in $(seq 1 60); do docker info >/dev/null 2>&1 && return 0; sleep 3; done
  grt_log "Docker not ready — start Docker Desktop, then re-run."
  return 1
}

# Pull the runner image if it's missing or older than GRT_IMAGE_MAX_AGE_DAYS.
# Best-effort: an offline pull must never block bringing a runner back up on
# the image we already have.
grt_ensure_image() {
  local created age_days
  if ! docker image inspect "$GRT_IMAGE" >/dev/null 2>&1; then
    grt_log "pulling $GRT_IMAGE…"
    docker pull "$GRT_IMAGE"
    return 0
  fi
  created="$(docker image inspect "$GRT_IMAGE" --format '{{.Created}}' 2>/dev/null || true)"
  [ -n "$created" ] || return 0
  age_days=$(( ($(date +%s) - $(date -d "$created" +%s 2>/dev/null || date +%s)) / 86400 ))
  if [ "$age_days" -ge "$GRT_IMAGE_MAX_AGE_DAYS" ]; then
    grt_log "runner image is ${age_days}d old — refreshing $GRT_IMAGE…"
    docker pull "$GRT_IMAGE" || grt_log "pull failed — continuing on the cached image."
  fi
}

# --- container state ---------------------------------------------------------
# Echoes the container's status ("running", "exited", …) or "" if it doesn't
# exist. NB: `docker inspect` on a missing container prints a blank line to
# stdout before failing, so strip whitespace to avoid a spurious value.
grt_container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | tr -d '[:space:]' || true
}

# --- runner online state (from GitHub) --------------------------------------
# echoes "k/N online" (plus ", j busy" while working) for this machine's
# runners on the repo, or "" if none are registered.
grt_runner_status() {
  local repo="$1" base count name status busy n=0 b=0
  base="$(grt_machine_name)"; count="$(grt_repo_count "$repo")"
  while read -r name status busy; do
    case "$name" in
      "$base"-[0-9]|"$base"-[0-9][0-9])
        [ "$status" = "online" ] && n=$((n+1))
        [ "$busy" = "true" ] && b=$((b+1))
        ;;
    esac
  done < <(gh_api "repos/$repo/actions/runners" \
             --jq '.runners[] | "\(.name) \(.status) \(.busy)"' 2>/dev/null || true)
  if [ "$n" -gt 0 ]; then
    if [ "$b" -gt 0 ]; then
      printf '%s/%s online, %s busy' "$n" "$count" "$b"
    else
      printf '%s/%s online' "$n" "$count"
    fi
  fi
}

# --- container aggregate state ------------------------------------------------
# echoes "k/N running" for the repo's runner containers, or "" if none exist.
grt_containers_running() {
  local repo="$1" count i n=0 seen=0
  count="$(grt_repo_count "$repo")"
  for i in $(seq 1 "$count"); do
    case "$(grt_container_state "$(grt_container_name "$repo" "$i")")" in
      running) n=$((n+1)); seen=1 ;;
      '') : ;;
      *) seen=1 ;;
    esac
  done
  if [ "$seen" -eq 1 ]; then printf '%s/%s running' "$n" "$count"; fi
}

# --- bring one repo's runners up (gated, boot-safe, idempotent) --------------
grt_start_one() {
  local repo="$1" mode count i container name old token started=0
  local -a caps
  mode="$(grt_get_mode "$repo")"
  if [ "$mode" != "self-hosted" ]; then
    grt_log "$repo: RUNNER='$mode' (GitHub-hosted) — nothing to start."
    return 0
  fi
  count="$(grt_repo_count "$repo")"
  grt_ensure_image

  # Retire pre-multi-instance leftovers (the unsuffixed container and the old
  # <repo>-pc registration) so an upgrade cleanly replaces them.
  local legacy_container legacy_name legacy_id
  legacy_container="$(grt_legacy_container_name "$repo")"
  if [ -n "$(grt_container_state "$legacy_container")" ]; then
    grt_log "$repo: retiring legacy container $legacy_container…"
    docker stop "$legacy_container" >/dev/null 2>&1 || true
    docker rm -f "$legacy_container" >/dev/null 2>&1 || true
  fi
  legacy_name="$(grt_legacy_runner_name "$repo")"
  legacy_id="$(gh_api "repos/$repo/actions/runners" --jq '.runners[] | "\(.id) \(.name)"' 2>/dev/null \
               | awk -v n="$legacy_name" '$2==n { print $1; exit }')" || legacy_id=""
  if [ -n "$legacy_id" ]; then
    grt_log "$repo: removing legacy runner registration $legacy_name (#$legacy_id)…"
    gh_api --method DELETE "repos/$repo/actions/runners/$legacy_id" >/dev/null 2>&1 || true
  fi

  for i in $(seq 1 "$count"); do
    container="$(grt_container_name "$repo" "$i")"
    name="$(grt_runner_name "$i")"
    if [ "$(grt_container_state "$container")" = "running" ]; then
      grt_log "$repo: $name already running."
      continue
    fi
    # No local container is up for this slot, so any GitHub registration by this
    # name is stale (e.g. left by an ungraceful shutdown) — remove it to avoid a
    # name collision.
    old="$(gh_api "repos/$repo/actions/runners" --jq '.runners[] | "\(.id) \(.name)"' 2>/dev/null \
           | awk -v n="$name" '$2==n { print $1; exit }')" || old=""
    if [ -n "$old" ]; then
      grt_log "$repo: removing stale runner #$old…"
      gh_api --method DELETE "repos/$repo/actions/runners/$old" >/dev/null 2>&1 || true
    fi
    grt_log "$repo: registering $name…"
    token="$(gh_api --method POST "repos/$repo/actions/runners/registration-token" --jq .token)"
    [ -n "$token" ] || { grt_log "$repo: could not get a registration token (check gh auth)."; return 1; }
    docker rm -f "$container" >/dev/null 2>&1 || true
    # Resource caps (tunables above) keep a busy runner from saturating the PC.
    # Auto-update stays ENABLED: GitHub retires old runner clients, and a pinned
    # client eventually looks online while every job fails "version too old".
    caps=()
    [ -n "$GRT_CPUS" ] && caps+=(--cpus "$GRT_CPUS")
    [ -n "$GRT_MEMORY" ] && caps+=(--memory "$GRT_MEMORY")
    docker run -d --name "$container" --restart no "${caps[@]}" \
      -e REPO_URL="https://github.com/$repo" \
      -e RUNNER_TOKEN="$token" \
      -e RUNNER_NAME="$name" \
      -e RUNNER_SCOPE="repo" \
      -e LABELS="$GRT_LABEL" \
      "$GRT_IMAGE" >/dev/null
    started=$((started+1))
  done
  grt_log "$repo: $count runner(s) up ($started newly started) — backlog (if any) will begin shortly."
}

# --- take one repo's runners down (graceful deregister) ----------------------
grt_stop_one() {
  local repo="$1" slug c
  slug="$(grt_repo_slug "$repo")"
  # Match every instance (<repo>-runner-N) plus the legacy unsuffixed name, so
  # count reductions and upgrades still clean up fully.
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${slug}-runner(-[0-9]+)?$" || true); do
    grt_log "$repo: stopping $c (graceful deregister)…"
    docker stop "$c" >/dev/null 2>&1 || true
    docker rm "$c" >/dev/null 2>&1 || true
  done
}

# --- billing -----------------------------------------------------------------
# Actions minutes consumed this calendar month, summed across all repos.
# Uses the Enhanced Billing usage endpoint (the classic one is 410 Gone).
# Echoes an integer, or "" if the billing API is unavailable.
grt_minutes_used() {
  local y m user
  y="$(date +%Y)"; m="$(( 10#$(date +%m) ))"; user="$(grt_user)"
  gh_api "users/$user/settings/billing/usage?year=$y&month=$m" \
    --jq '[.usageItems[] | select(.product=="actions" and .unitType=="Minutes") | .quantity] | add // 0' \
    2>/dev/null | awk '{ printf "%d", $1 + 0.5 }' || true
}
