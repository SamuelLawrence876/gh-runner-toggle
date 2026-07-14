# gh-runner-toggle — spec

A tiny, reusable tool to make any of my **private** GitHub repos fall back from
GitHub-hosted CI runners to a **free self-hosted runner on my own PC** when I run out of
Actions minutes — flipped by a single per-repo variable, and auto-resuming on login so I
never have to remember to turn it on.

Status: **BUILT & DEPLOYED.** This design is implemented in this repo
(`lib/common.sh` + `bin/grt-*`) and running in production against a private repo: the one-time
`runs-on` toggle PR is merged, and gated auto-start + auto-flip are installed. See
[`README.md`](README.md) for usage.

---

## 1. Motivation

- Personal GitHub account, a dozen or so projects, one very active. Hit the 2,000 min/month
  Actions cap for the first time.
- Want a fallback that (a) is **free** (uses hardware I already own), (b) doesn't require
  editing workflows every time I switch, and (c) **doesn't depend on me remembering** to start
  a runner when I boot the PC to clear a backlog.
- Self-hosted runner *usage* is still free/unmetered (a proposed $0.002/min charge for 1 Mar 2026
  was postponed indefinitely after backlash — see [Pricing context](#8-pricing-context)).

## 2. Goals

- **One variable, no workflow edits.** After a one-time setup, switching a repo's CI between
  GitHub-hosted and my PC is a single `RUNNER` Actions-variable flip — no code changes.
- **Backend-agnostic indirection.** Every job reads `runs-on: ${{ vars.RUNNER || 'ubuntu-latest' }}`.
  The value behind `RUNNER` is the only thing that changes — so the *backend* (my PC today, a
  cloud runner later) can change forever without touching a single workflow again.
- **Zero-friction resume.** While a repo is in fallback mode, the runner auto-starts on every
  Windows login and picks up any queued backlog. Gated so it's a no-op the rest of the time
  (preserves "use free GitHub minutes first").
- **Auto-flip on exhaustion.** A periodic local check reads remaining account Actions minutes and
  flips `RUNNER` to `self-hosted` (and back when minutes reset) on its own — I don't have to notice
  I've run out. Lag-tolerant by design (see §4.6). Manual `grt-up`/`grt-down` remain as overrides.
- **Reusable across repos** from one small, version-controlled repo (not scratch files).
- **Free by default**, with a documented, no-rework upgrade to always-on cloud.

## 3. Non-goals

- Not an autoscaler or high-throughput CI platform — that's ARC / RunsOn / CodeBuild territory.
  This targets a solo dev's occasional fallback, not a fleet.
- **Not always-available.** Compute is my desktop; jobs queue while it's off. Accepted trade-off
  of "free + my hardware." (See [cloud upgrade path](#7-always-on-upgrade-path).)
- Public repos are out of scope (a self-hosted runner on a public repo is an RCE risk from
  fork PRs).
- No Windows/macOS runner targets — workflows are Linux (`ubuntu-latest`, bash, `$GITHUB_OUTPUT`);
  the runner is a **Docker Linux** container so those steps run unchanged.
- Not a replacement for GitHub-hosted in normal operation — it's a fallback.

## 4. Core design

### 4.1 The toggle
Each covered repo has:
- Every job's `runs-on` rewritten to `${{ vars.RUNNER || 'ubuntu-latest' }}` (one-time, via PR).
- A repo **Actions variable `RUNNER`**:
  - unset / `ubuntu-latest` → GitHub-hosted (default, unchanged behaviour)
  - `self-hosted` → the local Docker runner

### 4.2 Mode vs capacity (the key decoupling)
- **`RUNNER` variable = the mode** (where jobs are routed). Changed at the two monthly
  transitions (out of minutes / minutes reset).
- **The container = capacity** (whether a runner is available right now). Managed independently.
- This separation is what makes auto-start safe: the boot script can bring the runner up only
  when the mode is `self-hosted`, and idle harmlessly otherwise.

### 4.3 The runner
- Image: `myoung34/github-runner:latest` — already bundles `git`, `jq`, and **AWS CLI v2**
  (needed by deploy/image workflows). Node is installed per-job by `actions/setup-node`, exactly
  like GitHub-hosted. No custom Dockerfile needed.
- Registers with label `self-hosted`, name `<machine>-<n>` (e.g. `sam-pc-1`) — the machine
  name comes from `hostname` (override with `GRT_RUNNER_BASENAME`). The name says *where the
  runner lives*; the registration itself is already repo-scoped. Container names stay
  repo-prefixed (`<repo>-runner-<n>`) since Docker's namespace is shared across repos.
- A repo can run **multiple instances** (the optional count column in `repos.txt`) so a
  workflow's parallel jobs actually run in parallel instead of queueing on one runner.
- Registration token fetched fresh each start via `gh api` — **no PAT stored on disk**.
- `--restart no`; reboots are handled by the login entry (so it can refresh the token), not
  Docker's restart policy.

### 4.4 Gated auto-start
- A Windows Startup entry runs the boot script at every login.
- Boot script: wait for Docker → for each repo in fallback mode, if no local runner is running,
  remove any stale same-named registration (from an ungraceful shutdown) and register a fresh
  runner. No-op for repos not in fallback mode.

### 4.5 Multi-repo model
- Personal accounts only allow **repo-level** runners (no account-wide) — so covering N repos =
  one (or more, per the count column) container per repo. A config file lists which repos are
  covered; the boot script and CLI loop over it.
- (The alternative — one org-level runner for all — requires a GitHub org migration; see
  [Scaling](#6-scaling).)

### 4.6 Auto-flip on minute exhaustion
- Actions minutes are billed **per account**, shared across all private repos — so the decision is
  **global**: one billing check flips *every* covered repo together (not per-repo).
- `grt-autoflip` runs periodically (Windows Task Scheduler, e.g. every 30–60 min):
  - reads remaining minutes via the GitHub billing API;
  - **remaining < margin** (e.g. 100 min, to absorb billing lag) and mode is GitHub →
    set all covered repos to `self-hosted` + ensure runners up;
  - **minutes reset** (new cycle, remaining back above margin) and mode is auto-`self-hosted` →
    set all back to `ubuntu-latest` + stop runners.
- **Lag-tolerant (accepted).** GitHub's usage figures trail real usage by minutes–hours. The margin
  means we switch *before* getting blocked; keep a GitHub **spending cap** as a backstop so any
  overshoot into paid minutes is bounded.
- **Manual override.** `grt-up`/`grt-down` still work and take precedence; auto-flip must respect a
  manual "hold" so a deliberate choice isn't reverted by the next check (see open questions).

## 5. Components & interface

Proposed layout for the `gh-runner-toggle` repo:

```
gh-runner-toggle/
  spec.md
  README.md
  repos.txt              # list of covered repos, one "owner/name" per line
  lib/common.sh          # shared: resolve repo, fetch token, container name, gh helpers
  bin/
    grt-add <owner/repo>   # onboard: set RUNNER var + open the runs-on toggle PR
    grt-up  [repo]         # enter fallback: RUNNER=self-hosted + start runner(s)
    grt-down [repo]        # exit fallback: RUNNER=ubuntu-latest + stop/deregister
    grt-start [repo]       # boot-safe, gated bring-up (used by auto-start); no var change
    grt-stop  [repo]       # stop/deregister container(s)
    grt-status             # per repo: mode, runner online/idle, container state
    grt-autoflip           # check remaining account minutes; flip ALL covered repos' mode
    grt-install-autostart  # write the Windows Startup entry
    grt-install-autoflip   # register the periodic minutes check (Windows Task Scheduler)
```

- With no `[repo]` arg, `grt-up/down/start/stop` act on **all repos in `repos.txt`**; with an arg,
  just that one.
- `grt-add` automates what was done by hand for the pilot: creates the `RUNNER` variable and opens
  a PR that rewrites `runs-on` across the repo's workflows.

### Everyday UX
```bash
grt-up            # "I'm out of minutes"  -> all covered repos fall back to my PC
grt-down          # "minutes reset"       -> back to GitHub-hosted
# in between: reboots auto-resume the runner for any repo still in fallback
```

## 6. Scaling

- **Now (recommended): one container per repo, personal account.** No migration, no disruption;
  OIDC/deploy trust policies untouched. Fine for a handful of active repos.
- **Later (only if it grows): free GitHub org + one org-level runner** serving all repos.
  Cleaner management, but a real migration — repo URLs change and, critically, **any AWS OIDC deploy
  roles scoped to `repo:<owner>/*` must be updated or prod deploys break.** Deferred
  until there are collaborators or many active repos.

## 7. Always-on upgrade path

The `RUNNER` indirection means the backend can change with **no workflow edits**:
- Point `RUNNER` at **AWS CodeBuild** managed runners, or adopt **RunsOn** (ephemeral EC2 in my
  own AWS account) — both are always-on, no PC dependency, ~a few $/month, scale to zero.
- Use a **maintained project for the cloud backend** (RunsOn / CodeBuild) — do NOT hand-roll
  autoscaling/ephemeral cloud runners; that's where from-scratch bites.
- Trigger to consider upgrading: the "PC must be on" constraint becomes annoying, or usage grows
  past what a desktop comfortably serves.

## 8. Pricing context

- Self-hosted runner minutes are **free today**. GitHub announced a $0.002/min "cloud platform"
  charge for 1 Mar 2026 but **postponed it indefinitely** after backlash.
- Not permanently cancelled — could return. Even if it does: ~$4/mo at ~2,000 min/mo usage, still
  cheaper than CodeBuild (~$9.50) or hosted overage. Doesn't break the approach.
- GitHub-**hosted** runner prices were cut up to 39% on 1 Jan 2026 (so paying GitHub for overage
  is cheaper than before, if ever preferred).

## 9. Security

- **Private repos only.**
- No PAT stored — registration tokens fetched per-start via the already-authenticated `gh` CLI
  (Windows keyring). Auto-start runs in the logged-in user context so it can reach the keyring.
- Runner runs in a container; treat it as trusted-code execution for repos I control.

## 10. Dependencies

- Docker Desktop (Linux engine) — **must be set to start on login** for auto-start to work; boot
  script waits up to ~3 min for the engine.
- `gh` CLI, authenticated **with a `user`-scoped token** (or a fine-grained PAT with *Plan: read*)
  so `grt-autoflip` can read remaining Actions minutes — the default `gh` token lacks it
  (`gh auth refresh -h github.com -s user`). **Validate first:** the classic
  `/users/{user}/settings/billing/actions` endpoint may be superseded by the Enhanced Billing
  Platform usage API on this account; confirm one returns real numbers before relying on auto-flip,
  else fall back to manual (`grt-up`/`grt-down`).
- Git Bash (`C:\Program Files\Git\bin\bash.exe`) for the Startup entry.

## 11. Pilot — current state

A private repo with a non-trivial CI/CD setup (CI jobs plus a prod deploy pipeline) is the
working pilot:
- A one-time PR rewrote `runs-on` for every job across the repo's workflows (CI, deploy, etc.)
  to `${{ vars.RUNNER || 'ubuntu-latest' }}`, then was merged deliberately (merging triggers the
  prod deploy).
- `RUNNER` variable created (default `ubuntu-latest`).
- Runner kit + gated auto-start built and verified end-to-end
  (register → online → stale-cleanup on simulated reboot → clean teardown).
- A first real prod deploy has since run to success on the self-hosted runner.
- Generalising this pilot into `gh-runner-toggle` is what this spec covers.

## 12. Open questions / decisions

1. **Config format** — flat `repos.txt`, or per-repo settings (label, runner name, image)? Start
   flat; extend if needed.
2. **Auto-detect out-of-minutes? — DECIDED: yes.** `grt-autoflip` on a periodic Task Scheduler
   check with a lag-tolerant margin (§4.6); lag is acceptable (owner confirmed). Needs a
   `user`-scoped token / Plan:read PAT. Remaining sub-questions:
   - **Endpoint:** verify classic billing vs Enhanced Billing usage API returns data for this account.
   - **Manual hold:** how to mark a deliberate `grt-up`/`grt-down` so the next auto-check doesn't
     revert it (e.g. a sentinel `RUNNER=self-hosted-hold`, or a local state file).
   - **Interval + margin:** default ~30–60 min check, ~100-min margin; tune to taste.
3. **Reboot token refresh** — current approach re-registers on login (fresh token, no stored
   secret). Alternative: store a fine-grained PAT and use Docker `--restart unless-stopped`.
   Prefer the no-stored-secret approach.
4. **One Startup entry looping over repos**, vs one per repo? Prefer a single entry that reads
   `repos.txt`.
5. **Migrate the pilot in-place** vs fresh build in `gh-runner-toggle` then retire the old
   untracked pilot kit? Prefer: build generalised, re-point the Startup entry, then delete
   the old kit.
6. **Should `grt-down` stop the container or leave it idling?** Stopping is cleaner; auto-start
   won't restart it while mode is `ubuntu-latest` anyway.

## 13. Rollout plan (when we build)

1. Scaffold `gh-runner-toggle` repo + `lib/common.sh` (repo-parameterised helpers).
2. Port the four pilot scripts into `bin/` as repo-aware commands; add `grt-add`, `grt-status`,
   `grt-install-autostart`.
3. Add `repos.txt`, seed with the first repo.
4. Re-point the Windows Startup entry at the new boot command; verify pilot still works.
5. **Auto-flip:** confirm a billing endpoint returns real minute numbers with a `user`-scoped
   token; build `grt-autoflip` (margin + manual-hold) and `grt-install-autoflip`; register the
   periodic check. Fall back to manual-only if no endpoint works.
6. Retire the old untracked pilot kit.
7. Onboard a second repo with `grt-add` to prove the generalisation.
```
