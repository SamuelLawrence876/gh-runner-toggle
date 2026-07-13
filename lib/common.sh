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
GRT_BIN_DIR="$GRT_ROOT/bin"
GRT_STATE_DIR="$GRT_ROOT/.state"
GRT_REPOS_FILE="$GRT_ROOT/repos.txt"

# --- tunables (override via environment) ------------------------------------
GRT_IMAGE="${GRT_IMAGE:-myoung34/github-runner:latest}"
GRT_LABEL="${GRT_LABEL:-self-hosted}"
GRT_QUOTA="${GRT_QUOTA:-2000}"    # included Actions minutes/month (free plan)
GRT_MARGIN="${GRT_MARGIN:-100}"   # flip to self-hosted when remaining < this

# --- logging -----------------------------------------------------------------
grt_log() { echo "[$(date '+%H:%M:%S')] $*"; }
grt_die() { echo "error: $*" >&2; exit 1; }

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
grt_all_repos() {
  [ -f "$GRT_REPOS_FILE" ] || return 0
  sed -E 's/#.*$//' "$GRT_REPOS_FILE" | awk 'NF { print $1 }'
}

# Which repos a command acts on: its args if any, else every covered repo.
grt_resolve_repos() {
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else grt_all_repos; fi
}

# --- naming ------------------------------------------------------------------
grt_repo_slug()      { printf '%s' "${1##*/}"; }          # owner/name -> name
grt_container_name() { printf '%s-runner' "$(grt_repo_slug "$1")"; }
grt_runner_name()    { printf '%s-pc' "$(grt_repo_slug "$1")"; }

# --- RUNNER variable (the "mode") -------------------------------------------
grt_get_mode() { gh_api "repos/$1/actions/variables/RUNNER" --jq .value 2>/dev/null || printf ''; }
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

# --- container state ---------------------------------------------------------
# Echoes the container's status ("running", "exited", …) or "" if it doesn't
# exist. NB: `docker inspect` on a missing container prints a blank line to
# stdout before failing, so strip whitespace to avoid a spurious value.
grt_container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | tr -d '[:space:]' || true
}

# --- runner online state (from GitHub) --------------------------------------
# echoes the runner's status ("online"/"offline") or "" if not registered.
grt_runner_status() {
  local repo="$1" name
  name="$(grt_runner_name "$repo")"
  gh_api "repos/$repo/actions/runners" \
    --jq '.runners[] | "\(.name) \(.status)"' 2>/dev/null \
    | awk -v n="$name" '$1==n { print $2; exit }' || true
}

# --- bring one repo's runner up (gated, boot-safe, idempotent) --------------
grt_start_one() {
  local repo="$1" mode container name old token
  mode="$(grt_get_mode "$repo")"
  if [ "$mode" != "self-hosted" ]; then
    grt_log "$repo: RUNNER='$mode' (GitHub-hosted) — nothing to start."
    return 0
  fi
  container="$(grt_container_name "$repo")"
  name="$(grt_runner_name "$repo")"
  if [ "$(grt_container_state "$container")" = "running" ]; then
    grt_log "$repo: runner already running."
    return 0
  fi
  docker image inspect "$GRT_IMAGE" >/dev/null 2>&1 || { grt_log "pulling $GRT_IMAGE…"; docker pull "$GRT_IMAGE"; }
  # No local runner is up, so any GitHub registration by this name is stale
  # (e.g. left by an ungraceful shutdown) — remove it to avoid a name collision.
  old="$(gh_api "repos/$repo/actions/runners" --jq '.runners[] | "\(.id) \(.name)"' 2>/dev/null \
         | awk -v n="$name" '$2==n { print $1; exit }')"
  if [ -n "$old" ]; then
    grt_log "$repo: removing stale runner #$old…"
    gh_api --method DELETE "repos/$repo/actions/runners/$old" >/dev/null 2>&1 || true
  fi
  grt_log "$repo: registering runner…"
  token="$(gh_api --method POST "repos/$repo/actions/runners/registration-token" --jq .token)"
  [ -n "$token" ] || { grt_log "$repo: could not get a registration token (check gh auth)."; return 1; }
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run -d --name "$container" --restart no \
    -e REPO_URL="https://github.com/$repo" \
    -e RUNNER_TOKEN="$token" \
    -e RUNNER_NAME="$name" \
    -e RUNNER_SCOPE="repo" \
    -e LABELS="$GRT_LABEL" \
    -e DISABLE_AUTO_UPDATE="true" \
    "$GRT_IMAGE" >/dev/null
  grt_log "$repo: runner started — backlog (if any) will begin shortly."
}

# --- take one repo's runner down (graceful deregister) ----------------------
grt_stop_one() {
  local repo="$1" container
  container="$(grt_container_name "$repo")"
  if [ -z "$(grt_container_state "$container")" ]; then
    return 0
  fi
  grt_log "$repo: stopping runner (graceful deregister)…"
  docker stop "$container" >/dev/null 2>&1 || true
  docker rm "$container" >/dev/null 2>&1 || true
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
