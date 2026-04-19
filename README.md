# mws — macOS Worktree Spin-up

> One command to spin up a dev workspace for any branch — git worktree + Cursor + Claude, wired together.

A small macOS CLI that turns "I want to work on branch X" into a single command: it creates a git worktree, opens a fresh iTerm2 window in it, launches Cursor on the folder, and starts a named Claude session. Removing a worktree is just as easy — with safety checks so you don't throw away uncommitted or unpushed work.

## What it does

- **`create`** — adds a git worktree, fetches the latest base branch from `origin`, creates (or reuses) a branch, then opens iTerm2 + Cursor + Claude on the new workspace.
- **`remove`** — tears down a worktree and deletes its branch, refusing if work would be lost.
- **`list`** — lists worktrees in the repo.
- **`prune`** — cleans up stale worktree metadata and orphaned branches whose directories no longer exist.

## Requirements

- **macOS** (uses `osascript` / iTerm2 automation)
- **iTerm2** — `https://iterm2.com`
- **Cursor** with the `cursor` shell command installed (Cursor → Command Palette → "Shell Command: Install 'cursor' command in PATH")
- **Claude CLI** (`claude`) on your `PATH`
- **git** (any recent version with worktree support, i.e. ≥ 2.5)

## Setup

Clone this repo and make the script executable (once):

```bash
chmod +x mws.sh
./mws.sh --help
```

No install step — run it directly from its directory with `./mws.sh`. The first run may trigger macOS prompts for Accessibility / Automation permissions so iTerm2 can be controlled via AppleScript — grant them to your terminal app.

## Usage

```text
./mws.sh <command> --dir <path> [options] [<branch-name>]
```

`--dir <path>` points at the git repository you're operating on and is **required** for every command — since you run `mws.sh` from this repo, `--dir` is how the script knows which target repo to operate on.

### create

Creates a worktree and a ready-to-use dev session.

```bash
# New branch from latest origin/main
./mws.sh create --dir ~/code/myrepo MM-1234-fix-bug

# New branch from a different base
./mws.sh create --dir ~/code/myrepo --base release-9.0 feature/new-widget

# Branch already exists (local or on origin) — it's checked out into the worktree
./mws.sh create --dir ~/code/myrepo existing-branch
```

Behavior:
- If the branch exists **locally**, it's checked out into the worktree as-is.
- If it exists only on `origin`, a local tracking branch is created from it.
- Otherwise, a new branch is created from `origin/<base>` (default `main`), fetching first so you start from the latest.

The worktree lives at `<repo-parent>/<repo-name>-<branch-name>`, with `/` in branch names replaced by `-` for a safe directory.

### remove

Removes a worktree and deletes its branch — with safety.

```bash
# Safe: refuses if uncommitted changes or unpushed commits
./mws.sh remove --dir ~/code/myrepo MM-1234-fix-bug

# Force: discards uncommitted / unpushed work
./mws.sh remove --dir ~/code/myrepo --force MM-1234-fix-bug
```

Without `--force`, it checks:
- No uncommitted changes in the worktree
- The branch is not ahead of its upstream

If either fails, it aborts with a per-issue message. `--force` (or `-f`) skips the checks and passes `--force` to `git worktree remove`.

### list

```bash
./mws.sh list --dir ~/code/myrepo
```

Wraps `git worktree list` — same output, but lets you run it from anywhere via `--dir`.

### prune

```bash
./mws.sh prune --dir ~/code/myrepo
```

Runs `git worktree prune -v`, then deletes local branches whose worktree directory no longer exists (i.e. someone `rm -rf`'d the folder). Prints each branch as it goes.

## Options reference

| Option | Applies to | Description |
|---|---|---|
| `--dir <path>` | all | Required. Path to the git repository. |
| `--base <branch>` | `create` | Base branch for new branches (default: `main`). Latest `origin/<base>` is fetched first. |
| `--force`, `-f` | `remove` | Skip safety checks; discard uncommitted / unpushed work. |

## Notes

- **macOS only.** The script automates iTerm2 via `osascript` and won't work on Linux/Windows.
- **No Space isolation.** Earlier versions fullscreened windows to isolate each workspace to its own macOS Space. That was removed — windows now open in your current Space. macOS has no public API for assigning windows to Spaces without fullscreen or a tool like `yabai` (which requires partial SIP disable).
- **Shell-quoting is safe.** Branch names and paths with spaces, apostrophes, or other shell metacharacters are passed to AppleScript as argv and escaped with `quoted form of` before hitting the iTerm2 shell session.

## Troubleshooting

- **"not inside a git repository"** — the `--dir` path isn't a git repo (or nested under one).
- **"directory already exists"** on `create` — an old worktree folder wasn't cleaned up. Run `./mws.sh remove --dir <path> <branch>` or `./mws.sh prune --dir <path>`.
- **Nothing happens in iTerm2** — grant your terminal app Accessibility + Automation permissions for iTerm2 in System Settings → Privacy & Security.
- **`cursor` command not found** — install it from Cursor's Command Palette ("Shell Command: Install 'cursor' command in PATH").
