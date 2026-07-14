# gh-runner-toggle (`grt`)

Make any of my **private** GitHub repos fall back from GitHub-hosted CI runners
to a **free self-hosted runner on this PC** when I run out of Actions minutes —
flipped by a single per-repo variable, auto-resuming on login, and (optionally)
auto-flipping the moment my minutes run low.

Bash CLI, driven by `gh` + `docker`. See [`spec.md`](spec.md) for the full design.

## How it works

Every job's `runs-on` reads `${{ vars.RUNNER || 'ubuntu-latest' }}`. The repo's
`RUNNER` Actions variable is the **only** thing that decides where CI runs:

| `RUNNER` value | CI runs on |
|---|---|
| unset / `ubuntu-latest` | GitHub-hosted (default) |
| `self-hosted` | a Docker Linux runner on this PC |

Two independent layers:

- **Mode** — the `RUNNER` variable (where jobs route).
- **Capacity** — the runner container(s) (whether a runner is available right now).

Runners are named after the machine (`sam-pc-1`, `sam-pc-2`, …), not the repo —
the registration is already repo-scoped, so the name only needs to say where the
runner lives. A repo can run several instances (the optional count column in
`repos.txt`, e.g. `owner/busy-repo 2`) so parallel workflow jobs genuinely run
in parallel instead of queueing on a single runner.

Decoupling them is what makes auto-start safe: the login script brings a runner
up **only** for repos whose mode is `self-hosted`, and idles otherwise.

## Install

Everything runs through a single `grt` dispatcher. Put its `bin/` on your PATH
once (add to `~/.bashrc`, using the path where you cloned this repo):

```bash
export PATH="$PATH:$HOME/projects/gh-runner-toggle/bin"
```

Then `grt` works as one word from any terminal. (The underlying `grt-up`,
`grt-down`, … scripts remain directly callable if you prefer.)

## Everyday use

```bash
grt               # status: mode / runner / container per repo + this month's minutes
grt up            # "I'm out of minutes"  -> all covered repos -> this PC
grt down          # "minutes reset"       -> back to GitHub-hosted
grt help          # full command list
```

`grt up`/`grt down` set a **manual hold** so auto-flip won't override your
choice; the hold auto-expires next billing month, or clear it now with `grt auto`.
Pass an `owner/repo` to act on just one repo instead of all.

## Set-and-forget (recommended)

```bash
grt add <owner/repo>       # onboard: RUNNER var + toggle PR + repos.txt
grt install-autostart      # login: auto-resume runners for repos in fallback
grt install-autoflip       # every 30 min: flip on/off from real minute usage
```

With all three, you never touch anything: `grt autoflip` reads your remaining
account Actions minutes and, when they drop below the margin, flips **all**
covered repos to self-hosted and brings runners up; when the month resets it
flips everything back. (Minutes are billed per account, so it's one global
decision.) Reboots auto-resume via the Startup entry.

## Commands

| Command | Does |
|---|---|
| `grt` or `grt status` | per-repo mode/runner/container + minute usage + hold state |
| `grt up [repo]` | fallback: `RUNNER=self-hosted` + start runner(s) + manual hold |
| `grt down [repo]` | exit: `RUNNER=ubuntu-latest` + stop runner(s) + manual hold |
| `grt add <owner/repo>` | onboard a repo: RUNNER var + `runs-on` toggle PR + repos.txt |
| `grt start [repo]` | gated, boot-safe bring-up (used by auto-start); no mode change |
| `grt stop [repo]` | stop + deregister runner container(s) |
| `grt logs [repo] [-n N]` | tail the runner containers' Docker logs |
| `grt autoflip` | flip all covered repos from live minute usage (Task Scheduler) |
| `grt auto` | release a manual hold now (hand control back to auto-flip) |
| `grt install-autostart` | write the Windows Startup entry |
| `grt install-autoflip` | register the periodic minutes check (Task Scheduler) |
| `grt help` | list all commands |

With no `[repo]`, the up/down/start/stop commands act on **all** repos in
`repos.txt`.

## Configuration

- `repos.txt` — covered repos, one `owner/name [count] [docker]` per line
  (count = runner instances for that repo, default 1; the `docker` token mounts
  the host Docker socket into that repo's runners so docker-building jobs —
  e.g. `cdk deploy` with container image assets — work self-hosted. **Opt-in
  only:** it hands that repo's CI control of Docker on this PC, which is
  root-equivalent — grant it per repo you trust end-to-end, incl. its npm
  dependency tree).
- Env overrides: `GRT_QUOTA` (included minutes/month, default `2000`),
  `GRT_MARGIN` (flip threshold, default `100`), `GRT_IMAGE`, `GRT_LABEL`,
  `GRT_CPUS` / `GRT_MEMORY` (per-container caps, default `4` / `6g`, `""` = uncapped),
  `GRT_IMAGE_MAX_AGE_DAYS` (re-pull the runner image past this age, default `7`),
  `GRT_RUNNER_BASENAME` (runner name prefix, default from `hostname`),
  `GRT_AUTOFLIP_MINUTES` (check interval, default `30`), `GRT_BASH_EXE`.

## Guard rails (what keeps it healthy unattended)

- **Runner freshness** — the runner client auto-updates in place, and the image
  is re-pulled once it's older than `GRT_IMAGE_MAX_AGE_DAYS`. (GitHub retires
  old runner clients: a pinned one eventually looks online while every job
  fails "version too old".)
- **Capacity self-heals** — every auto-flip check reconciles containers to each
  repo's mode, even under a manual hold, so a Docker restart never strands the
  runners until the next login.
- **Resource caps** — each container is capped (`GRT_CPUS`/`GRT_MEMORY`) so a
  busy runner can't saturate the PC while you're using it.
- **You get told** — a Windows toast fires whenever auto-flip moves CI onto or
  off this PC. Logs self-truncate.
- **Docker hygiene** — a weekly pass (piggybacked on auto-flip) prunes the CI
  leftovers that otherwise grow forever: dangling layers from runner-image
  re-pulls, local `cdkasset-*` tags (ECR holds the published copies), and
  build cache unused for a week. Other projects' images are never touched.
- **Known assumption** — minute usage + hold expiry work on the *calendar*
  month. If your GitHub billing cycle resets mid-month, the flip-back can run
  up to a cycle late/early; the margin absorbs small drift.

## Requirements

- **Docker Desktop** (Linux engine), set to **start on login** for unattended
  auto-start; the boot script waits up to ~3 min for the engine.
- **`gh` CLI**, authenticated with a **`user`-scoped** token so auto-flip can
  read minute usage: `gh auth refresh -h github.com -s user`.
- **Git Bash** (`C:\Program Files\Git\bin\bash.exe`) — invoked by the Windows
  entries.

## Notes / safety

- **Private repos only** (a self-hosted runner on a public repo is an RCE risk
  from fork PRs).
- **No PAT on disk** — registration tokens are fetched fresh each start via the
  already-authenticated `gh` CLI (Windows keyring).
- The runner image `myoung34/github-runner:latest` bundles `git`, `jq` and
  **AWS CLI v2**; Node is installed per-job by `actions/setup-node`.
- Auto-flip is **lag-tolerant** — GitHub's usage numbers trail real usage, so it
  switches early (the margin) and you should keep a GitHub **spending cap** as a
  hard backstop.
- Jobs **queue** (they don't fail) while the PC is off; they run when it's back
  and the runner is online.
