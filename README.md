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
- **Capacity** — the runner container (whether a runner is available right now).

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
| `grt autoflip` | flip all covered repos from live minute usage (Task Scheduler) |
| `grt auto` | release a manual hold now (hand control back to auto-flip) |
| `grt install-autostart` | write the Windows Startup entry |
| `grt install-autoflip` | register the periodic minutes check (Task Scheduler) |
| `grt help` | list all commands |

With no `[repo]`, the up/down/start/stop commands act on **all** repos in
`repos.txt`.

## Configuration

- `repos.txt` — covered repos, one `owner/name` per line.
- Env overrides: `GRT_QUOTA` (included minutes/month, default `2000`),
  `GRT_MARGIN` (flip threshold, default `100`), `GRT_IMAGE`, `GRT_LABEL`,
  `GRT_AUTOFLIP_MINUTES` (check interval, default `30`), `GRT_BASH_EXE`.

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
