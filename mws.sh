#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./mws.sh <command> --dir <path> [options] [<branch-name>]

Required:
  --dir <path>     Path to the git repository the command should run against.

Commands:

  create <branch-name> [--base <branch>]
    Create or reuse a git worktree, open iTerm2, start a Claude session, and
    launch Cursor. If <branch-name> exists locally or on origin, it is reused.
    Otherwise a new branch is created from --base (default: main), fetching
    origin/<base> first.

    Examples:
      ./mws.sh create --dir ~/Workspace/mattermost/mattermost-plugin-calls MM-1234-fix-bug
      ./mws.sh create --dir ~/Workspace/mattermost/mattermost-plugin-calls --base release-9.0 feature/new-widget
      ./mws.sh create --dir ~/Workspace/mattermost/mattermost-plugin-calls existing-branch

  remove <branch-name> [--force]
    Remove a worktree and delete its branch. Refuses if the worktree has
    uncommitted changes or the branch is ahead of its upstream; --force skips
    these checks and discards the work.

    Examples:
      ./mws.sh remove --dir ~/Workspace/mattermost/mattermost-plugin-calls MM-1234-fix-bug
      ./mws.sh remove --dir ~/Workspace/mattermost/mattermost-plugin-calls --force MM-1234-fix-bug

  list
    List all worktrees in the repository (wraps 'git worktree list').

    Examples:
      ./mws.sh list --dir ~/Workspace/mattermost/mattermost-plugin-calls

  prune
    Remove stale worktree metadata and delete orphaned branches whose worktree
    directory no longer exists.

    Examples:
      ./mws.sh prune --dir ~/Workspace/mattermost/mattermost-plugin-calls
USAGE
}

cmd_create() {
    local branch_name="$1"
    local base_branch="$2"

    # Must be inside a git repo
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "Error: not inside a git repository" >&2
        exit 1
    }

    local repo_name
    repo_name=$(basename "$repo_root")

    # Replace slashes in branch name for a safe directory name
    local dir_name="${branch_name//\//-}"
    local worktree_path="${repo_root}/../${repo_name}-${dir_name}"
    local source_desc
    local reused_existing_worktree="false"

    # Reuse an existing matching worktree when the target directory already exists.
    # Otherwise fail with a clear reason.
    if [[ -d "$worktree_path" ]]; then
        local repo_common_dir expected_common_dir existing_common_dir existing_branch
        repo_common_dir=$(git rev-parse --git-common-dir)
        if [[ "$repo_common_dir" = /* ]]; then
            expected_common_dir=$(cd "$repo_common_dir" && pwd)
        else
            expected_common_dir=$(cd "$repo_root/$repo_common_dir" && pwd)
        fi
        existing_common_dir=$(git -C "$worktree_path" rev-parse --git-common-dir 2>/dev/null || true)

        if [[ -n "$existing_common_dir" ]]; then
            if [[ "$existing_common_dir" = /* ]]; then
                existing_common_dir=$(cd "$existing_common_dir" && pwd)
            else
                existing_common_dir=$(cd "$worktree_path/$existing_common_dir" && pwd)
            fi
            if [[ "$existing_common_dir" == "$expected_common_dir" ]]; then
                existing_branch=$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
                if [[ "$existing_branch" == "$branch_name" ]]; then
                    source_desc="existing worktree"
                    reused_existing_worktree="true"
                    echo "Reusing existing worktree..."
                    echo "  Branch: ${branch_name} (${source_desc})"
                else
                    echo "Error: directory already exists but is checked out to '${existing_branch:-detached HEAD}': ${worktree_path}" >&2
                    echo "Run './mws.sh remove ${existing_branch}' first, or choose a different name." >&2
                    exit 1
                fi
            else
                echo "Error: directory already exists and belongs to a different repository: ${worktree_path}" >&2
                echo "Run './mws.sh remove ${branch_name}' first, or choose a different name." >&2
                exit 1
            fi
        else
            echo "Error: directory already exists and is not a git worktree: ${worktree_path}" >&2
            echo "Run './mws.sh remove ${branch_name}' first, or choose a different name." >&2
            exit 1
        fi
    fi

    # Reuse the branch if it already exists locally or on origin; otherwise create it
    if [[ "$reused_existing_worktree" != "true" ]]; then
        if git show-ref --verify --quiet "refs/heads/${branch_name}"; then
            source_desc="existing local branch"
            echo "Creating worktree..."
            echo "  Branch: ${branch_name} (${source_desc})"
            git worktree add "$worktree_path" "$branch_name"
        elif git show-ref --verify --quiet "refs/remotes/origin/${branch_name}"; then
            source_desc="tracking origin/${branch_name}"
            echo "Creating worktree..."
            echo "  Branch: ${branch_name} (${source_desc})"
            git worktree add -b "$branch_name" "$worktree_path" "origin/${branch_name}"
        else
            # New branch: fetch origin/<base> first so we start from the latest.
            # If origin doesn't have <base> (purely local base), fall back to local.
            local start_point="$base_branch"
            if git ls-remote --exit-code --heads origin "$base_branch" >/dev/null 2>&1; then
                echo "Fetching origin/${base_branch}..."
                git fetch origin "$base_branch" || echo "  (fetch failed, using local ${base_branch})" >&2
                start_point="origin/${base_branch}"
            fi
            source_desc="new, based on ${start_point}"
            echo "Creating worktree..."
            echo "  Branch: ${branch_name} (${source_desc})"
            git worktree add -b "$branch_name" "$worktree_path" "$start_point"
        fi
    fi

    # Resolve to absolute path
    worktree_path=$(cd "$worktree_path" && pwd)

    echo "Opening workspace..."

    # Pass path and branch as AppleScript argv so any quotes/apostrophes in them
    # can't break out of the heredoc or the inner shell command.
    # 'quoted form of' handles shell-escaping for iTerm2's shell session.
    # Open two tabs: first for Claude, second as a plain shell in the worktree.
    osascript \
        -e 'on run argv
                set thePath to item 1 of argv
                set theBranch to item 2 of argv
                set claudeCmd to "cd " & quoted form of thePath & " && cursor . && claude --name " & quoted form of theBranch
                set cdCmd to "cd " & quoted form of thePath
                tell application "iTerm2"
                    activate
                    set newWindow to (create window with default profile)
                    tell current session of newWindow
                        write text claudeCmd
                    end tell
                    tell newWindow
                        create tab with default profile
                    end tell
                    tell current session of current tab of newWindow
                        write text cdCmd
                    end tell
                end tell
            end run' \
        -- "$worktree_path" "$branch_name"

    echo ""
    echo "Workspace ready!"
    echo "  Worktree : ${worktree_path}"
    echo "  Branch   : ${branch_name} (${source_desc})"
}

cmd_remove() {
    local branch_name="$1"
    local force="${2:-}"

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "Error: not inside a git repository" >&2
        exit 1
    }

    local repo_name
    repo_name=$(basename "$repo_root")
    local dir_name="${branch_name//\//-}"
    local worktree_path="${repo_root}/../${repo_name}-${dir_name}"

    if [[ ! -d "$worktree_path" ]]; then
        echo "Error: worktree directory not found: ${worktree_path}" >&2
        exit 1
    fi

    # Safety checks — skipped with --force
    if [[ "$force" != "true" ]]; then
        local problems=()

        if [[ -n "$(git -C "$worktree_path" status --porcelain 2>/dev/null)" ]]; then
            problems+=("uncommitted changes in the worktree")
        fi

        local upstream
        upstream=$(git -C "$worktree_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
        if [[ -n "$upstream" ]]; then
            local ahead
            ahead=$(git -C "$worktree_path" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)
            if (( ahead > 0 )); then
                problems+=("branch is ${ahead} commit(s) ahead of ${upstream}")
            fi
        fi

        if (( ${#problems[@]} > 0 )); then
            echo "Refusing to remove worktree '${branch_name}':" >&2
            for p in "${problems[@]}"; do
                echo "  - $p" >&2
            done
            echo "" >&2
            echo "Push/commit your work, or re-run with --force to discard it." >&2
            exit 1
        fi
    fi

    echo "Removing worktree at ${worktree_path}..."
    if [[ "$force" == "true" ]]; then
        git worktree remove --force "$worktree_path"
    else
        git worktree remove "$worktree_path"
    fi

    echo "Deleting local branch ${branch_name}..."
    git branch -D "$branch_name" 2>/dev/null || echo "  (branch not found or already deleted)"

    echo "Done."
}

cmd_list() {
    git rev-parse --show-toplevel >/dev/null 2>&1 || {
        echo "Error: not inside a git repository" >&2
        exit 1
    }
    git worktree list
}

cmd_prune() {
    git rev-parse --show-toplevel >/dev/null 2>&1 || {
        echo "Error: not inside a git repository" >&2
        exit 1
    }

    # Collect branches for worktree entries git considers prunable (missing dir, etc.)
    local prunable_branches=()
    local current_branch="" current_prunable=0
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if (( current_prunable )) && [[ -n "$current_branch" ]]; then
                prunable_branches+=("$current_branch")
            fi
            current_branch=""
            current_prunable=0
        elif [[ "$line" == "branch refs/heads/"* ]]; then
            current_branch="${line#branch refs/heads/}"
        elif [[ "$line" == prunable* ]]; then
            current_prunable=1
        fi
    done < <(git worktree list --porcelain; printf '\n')

    echo "Pruning worktree metadata..."
    git worktree prune -v

    if (( ${#prunable_branches[@]} == 0 )); then
        echo "No orphaned branches to delete."
        return
    fi

    echo ""
    echo "Deleting orphaned branches..."
    for b in "${prunable_branches[@]}"; do
        echo "  - $b"
        git branch -D "$b" 2>/dev/null || echo "    (branch not found or already deleted)"
    done
}

# --- Main ---

command="${1:-}"
case "$command" in
    create|remove|rm|list|ls|prune)
        shift
        ;;
    -h|--help|help|"")
        usage
        exit 0
        ;;
    *)
        echo "Error: unknown command '${command}'" >&2
        echo ""
        usage
        exit 1
        ;;
esac

# Parse options (must come after the command, before the branch name)
base_branch="main"
force=""
dir_provided=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            if [[ $# -lt 2 ]]; then
                echo "Error: --dir requires a path argument" >&2
                exit 1
            fi
            cd "$2" || { echo "Error: cannot cd to '$2'" >&2; exit 1; }
            dir_provided="true"
            shift 2
            ;;
        --base)
            if [[ $# -lt 2 ]]; then
                echo "Error: --base requires a branch argument" >&2
                exit 1
            fi
            base_branch="$2"
            shift 2
            ;;
        --force|-f)
            force="true"
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            echo ""
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ "$dir_provided" != "true" ]]; then
    echo "Error: --dir <path> is required" >&2
    echo ""
    usage
    exit 1
fi

case "$command" in
    create|remove|rm)
        if [[ $# -lt 1 ]]; then
            echo "Error: branch name is required" >&2
            echo ""
            usage
            exit 1
        fi
        ;;
esac

case "$command" in
    create)
        if [[ "$force" == "true" ]]; then
            echo "Warning: --force has no effect on create; ignoring" >&2
        fi
        cmd_create "$1" "$base_branch"
        ;;
    remove|rm)
        cmd_remove "$1" "$force"
        ;;
    list|ls)
        cmd_list
        ;;
    prune)
        cmd_prune
        ;;
esac
