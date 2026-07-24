#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./mws.sh <command> --dir <path> [options]

Arguments may be provided in any order where unambiguous.

Required:
  --dir <path>     Path to the git repository the command should run against.
  --branch <name>  Branch name. Required for create/remove.

Commands:

  create --branch <name> [--base <branch>]
    Create or reuse a git worktree, open iTerm2, start a Claude session, and
    launch Cursor. If <branch-name> exists locally or on origin, it is reused.
    Otherwise a new branch is created from --base (default: main), fetching
    origin/<base> first.

    Examples:
      ./mws.sh create --dir ~/Workspace/mattermost/mattermost-plugin-calls --branch MM-1234-fix-bug
      ./mws.sh create --dir ~/Workspace/mattermost/mattermost-plugin-calls --base release-9.0 --branch feature/new-widget 
      ./mws.sh create --dir ~/Workspace/mattermost/mattermost-plugin-calls --branch existing-branch

  remove --branch <name> [--force]
    Remove a worktree and delete its branch. Refuses if the worktree has
    uncommitted changes or the branch is ahead of its upstream; --force skips
    these checks and discards the work.

    Examples:
      ./mws.sh remove --dir ~/Workspace/mattermost/mattermost-plugin-calls --branch MM-1234-fix-bug
      ./mws.sh remove --dir ~/Workspace/mattermost/mattermost-plugin-calls --branch MM-1234-fix-bug --force

  multi-remove <name>... [--force]
    Remove multiple worktrees in one call. Without --force, runs the same
    safety checks as 'remove' across ALL branches first and aborts the entire
    operation if ANY branch has uncommitted changes or unpushed commits — so
    nothing is removed unless everything is safe. With --force, removes each
    branch best-effort and continues past per-branch failures.

    Examples:
      ./mws.sh multi-remove --dir ~/Workspace/mattermost/mattermost-plugin-calls MM-1 MM-2 MM-3
      ./mws.sh multi-remove --dir ~/Workspace/mattermost/mattermost-plugin-calls MM-1 MM-2 --force

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
            git worktree add -b "$branch_name" --no-track "$worktree_path" "$start_point"
            # Point upstream at origin/<same-name>, not origin/<base>. The remote
            # ref doesn't exist yet; the first push creates it, after which
            # push/pull resolve to the matching remote branch.
            git -C "$worktree_path" config "branch.${branch_name}.remote" origin
            git -C "$worktree_path" config "branch.${branch_name}.merge" "refs/heads/${branch_name}"
            # Record the base branch and creation time so 'list' can show
            # where this branch came from and when it was created.
            git -C "$worktree_path" config "branch.${branch_name}.mwsBase" "$base_branch"
            git -C "$worktree_path" config "branch.${branch_name}.mwsCreatedAt" "$(date +%s)"
        fi
    fi

    # Resolve to absolute path
    worktree_path=$(cd "$worktree_path" && pwd)

    # If a prior Claude session for this worktree was tagged with --name <branch>,
    # resume it by its session ID. Sessions live at
    # ~/.claude/projects/<cwd-with-slashes-as-dashes>/<session-id>.jsonl and
    # contain a {"type":"custom-title","customTitle":"<name>"} entry.
    local claude_subcmd="--name ${branch_name}"
    local claude_project_dir="${HOME}/.claude/projects/${worktree_path//\//-}"
    local needle="\"customTitle\":\"${branch_name}\""
    local f session_id=""
    while IFS= read -r f; do
        if grep -Fq "$needle" "$f"; then
            session_id=$(basename "$f" .jsonl)
            break
        fi
    done < <(ls -t "${claude_project_dir}"/*.jsonl 2>/dev/null)
    if [[ -n "$session_id" ]]; then
        claude_subcmd="--resume ${session_id}"
    fi

    echo "Opening workspace..."

    # Pass path, branch, and claude args as AppleScript argv so any quotes/apostrophes
    # in them can't break out of the heredoc or the inner shell command.
    # 'quoted form of' handles shell-escaping for iTerm2's shell session.
    # Open two tabs: first for Claude, second as a plain shell in the worktree.
    osascript \
        -e 'on run argv
                set thePath to item 1 of argv
                set theClaudeArgs to item 2 of argv
                set claudeCmd to "cd " & quoted form of thePath & " && cursor . && claude " & theClaudeArgs
                set cdCmd to "cd " & quoted form of thePath
                tell application id "com.googlecode.iterm2"
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
        -- "$worktree_path" "$claude_subcmd"

    echo ""
    echo "Workspace ready!"
    echo "  Worktree : ${worktree_path}"
    echo "  Branch   : ${branch_name} (${source_desc})"
    if [[ -n "$session_id" ]]; then
        echo "  Claude   : resuming session ${session_id}"
    else
        echo "  Claude   : new session"
    fi
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

cmd_multi_remove() {
    local force="$1"; shift
    local branches=("$@")

    if (( ${#branches[@]} == 0 )); then
        echo "Error: multi-remove requires at least one branch name" >&2
        exit 1
    fi

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "Error: not inside a git repository" >&2
        exit 1
    }
    local repo_name
    repo_name=$(basename "$repo_root")

    # Resolve every branch to a worktree path; bail if any directory is missing.
    local paths=() missing=()
    local b dir_name p
    for b in "${branches[@]}"; do
        dir_name="${b//\//-}"
        p="${repo_root}/../${repo_name}-${dir_name}"
        if [[ ! -d "$p" ]]; then
            missing+=("$b")
        fi
        paths+=("$p")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "Error: worktree directories not found for:" >&2
        for b in "${missing[@]}"; do echo "  - $b" >&2; done
        exit 1
    fi

    # Safety check phase — atomic. Collect all problems, then either abort
    # cleanly (no removals) or proceed to remove every branch.
    if [[ "$force" != "true" ]]; then
        local blocked=()
        local i=0
        for b in "${branches[@]}"; do
            p="${paths[$i]}"
            local problems=()
            if [[ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]]; then
                problems+=("uncommitted changes")
            fi
            local upstream ahead
            upstream=$(git -C "$p" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || upstream=""
            if [[ -n "$upstream" ]]; then
                ahead=$(git -C "$p" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)
                if (( ahead > 0 )); then
                    problems+=("${ahead} commit(s) ahead of ${upstream}")
                fi
            fi
            if (( ${#problems[@]} > 0 )); then
                local joined="${problems[*]}"
                blocked+=("${b}: ${joined// /, }")
            fi
            i=$((i+1))
        done
        if (( ${#blocked[@]} > 0 )); then
            echo "Refusing to remove (nothing was removed):" >&2
            for line in "${blocked[@]}"; do echo "  - $line" >&2; done
            echo "" >&2
            echo "Push/commit your work, or re-run with --force to discard it." >&2
            exit 1
        fi
    fi

    # Remove phase. With --force, individual failures don't stop the rest.
    local total=${#branches[@]} removed=0 failed=0
    local i=0
    for b in "${branches[@]}"; do
        p="${paths[$i]}"
        echo "[$((i+1))/${total}] Removing ${b} at ${p}..."
        local rm_ok=0
        if [[ "$force" == "true" ]]; then
            git worktree remove --force "$p" && rm_ok=1 || true
        else
            git worktree remove "$p" && rm_ok=1 || true
        fi
        if (( rm_ok == 1 )); then
            git branch -D "$b" 2>/dev/null || echo "  (branch not found or already deleted)"
            removed=$((removed+1))
        else
            echo "  worktree removal failed" >&2
            failed=$((failed+1))
        fi
        i=$((i+1))
    done

    echo ""
    if (( failed > 0 )); then
        echo "Done. Removed ${removed}/${total} (failed: ${failed})."
        exit 1
    else
        echo "Done. Removed ${removed}/${total}."
    fi
}

cmd_list() {
    git rev-parse --show-toplevel >/dev/null 2>&1 || {
        echo "Error: not inside a git repository" >&2
        exit 1
    }

    local base_dir repo_name
    base_dir=$(pwd)
    repo_name=$(basename "$base_dir")
    shorten_path() {
        local target="$1"
        local target_abs
        target_abs=$(cd "$target" 2>/dev/null && pwd) || { echo "$target"; return; }
        if [[ "$target_abs" == "$base_dir" ]]; then
            echo "."
        elif [[ "$target_abs" == "$base_dir"/* ]]; then
            echo "${target_abs#$base_dir/}"
        elif [[ "$(dirname "$target_abs")" == "$(dirname "$base_dir")" ]]; then
            echo "../$(basename "$target_abs")"
        else
            echo "${target_abs/#$HOME/~}"
        fi
    }

    local rows=()
    local path="" head="" branch=""
    flush_row() {
        if [[ -n "$path" ]]; then
            local short_head="${head:0:7}"
            local branch_display="${branch:-(detached)}"
            local origin="-" base="-" created="-" mismatch=""
            # Flag worktrees whose directory suffix doesn't match the dir-safe
            # form of the checked-out branch (e.g., someone ran `git checkout`
            # inside the worktree and orphaned its original branch).
            if [[ -n "$branch" ]]; then
                local dir_basename expected_suffix actual_suffix
                dir_basename=$(basename "$path")
                if [[ "$dir_basename" != "$repo_name" ]]; then
                    expected_suffix="${branch//\//-}"
                    actual_suffix="${dir_basename#${repo_name}-}"
                    if [[ "$actual_suffix" != "$expected_suffix" ]]; then
                        mismatch="!"
                    fi
                fi
            fi
            if [[ -n "$branch" && -d "$path" ]]; then
                origin=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || origin="-"
                [[ -z "$origin" ]] && origin="-"
                # Prefer the base recorded by 'create'; otherwise try to recover
                # it from reflog (oldest 'branch: Created from <ref>' entry).
                base=$(git -C "$path" config --get "branch.${branch}.mwsBase" 2>/dev/null || true)
                if [[ -z "$base" ]]; then
                    base=$(git -C "$path" reflog show --no-abbrev "$branch" 2>/dev/null \
                        | awk -F'Created from ' '/Created from /{print $2}' \
                        | tail -1)
                    base="${base#refs/remotes/}"
                    base="${base#refs/heads/}"
                    base="${base:--}"
                fi
                # Prefer the timestamp recorded by 'create'; otherwise use the
                # oldest reflog entry's timestamp as a proxy for branch birth.
                local ts
                ts=$(git -C "$path" config --get "branch.${branch}.mwsCreatedAt" 2>/dev/null || true)
                if [[ -z "$ts" ]]; then
                    ts=$(git -C "$path" reflog show --date=unix "$branch" 2>/dev/null \
                        | tail -1 \
                        | grep -oE '@\{[0-9]+\}' \
                        | tr -d '@{}')
                fi
                if [[ -n "$ts" ]]; then
                    created=$(date -r "$ts" "+%d-%m-%y %H:%M" 2>/dev/null || echo "-")
                fi
            fi
            local display_path
            display_path=$(shorten_path "$path")
            local branch_cell="${mismatch:+! }${branch_display}"
            # Prefix with sortable timestamp; unknown rows get a far-future value
            # so they sink to the bottom under an ascending sort.
            rows+=("${ts:-9999999999}"$'\t'"${branch_cell}"$'\t'"${base}"$'\t'"${origin}"$'\t'"${short_head}"$'\t'"${created}"$'\t'"${display_path}")
        fi
        path="" head="" branch=""
    }
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            flush_row
        elif [[ "$line" == "worktree "* ]]; then
            path="${line#worktree }"
        elif [[ "$line" == "HEAD "* ]]; then
            head="${line#HEAD }"
        elif [[ "$line" == "branch refs/heads/"* ]]; then
            branch="${line#branch refs/heads/}"
        elif [[ "$line" == "detached" ]]; then
            branch=""
        fi
    done < <(git worktree list --porcelain; printf '\n')

    local all_rows=()
    all_rows+=("BranchName"$'\t'"BaseBranch"$'\t'"GitOrigin"$'\t'"HeadCommit"$'\t'"CreatedAt"$'\t'"LocalPath")
    while IFS= read -r sorted_row; do
        all_rows+=("$sorted_row")
    done < <(
        for row in "${rows[@]}"; do
            printf '%s\n' "$row"
        done | sort -t $'\t' -k1,1n | cut -f2-
    )

    # 0=BranchName 1=BaseBranch 2=GitOrigin 3=HeadCommit 4=CreatedAt 5=LocalPath
    local visible=(0 1 2 4)
    local ncols=${#visible[@]}
    local widths=(0 0 0 0)
    for row in "${all_rows[@]}"; do
        IFS=$'\t' read -ra fields <<< "$row"
        for vi in "${!visible[@]}"; do
            local ci=${visible[$vi]} len=${#fields[${visible[$vi]}]}
            (( len > widths[vi] )) && widths[vi]=$len
        done
    done

    repeat_char() { local c="$1" n="$2" s="" j; for ((j=0;j<n;j++)); do s+="$c"; done; printf "%s" "$s"; }

    draw_border() {
        local type="$1" left mid right sep
        case "$type" in
            top) left="┌"; mid="┬"; right="┐"; sep="─" ;;
            mid) left="├"; mid="┼"; right="┤"; sep="─" ;;
            bot) left="└"; mid="┴"; right="┘"; sep="─" ;;
        esac
        printf "%s" "$left"
        for i in "${!widths[@]}"; do
            repeat_char "$sep" $(( widths[i] + 2 ))
            (( i < ncols - 1 )) && printf "%s" "$mid"
        done
        printf "%s\n" "$right"
    }

    print_row() {
        IFS=$'\t' read -ra fields <<< "$1"
        printf "│"
        for vi in $(seq 0 $(( ncols - 1 ))); do
            printf " %-*s │" "${widths[$vi]}" "${fields[${visible[$vi]}]:-}"
        done
        printf "\n"
    }

    draw_border top
    print_row "${all_rows[0]}"
    draw_border mid
    for i in $(seq 1 $(( ${#all_rows[@]} - 1 ))); do
        print_row "${all_rows[$i]}"
    done
    draw_border bot
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

# Parse options and command in any order where unambiguous.
command=""
base_branch="main"
branch_name=""
branch_provided=""
force=""
dir_provided=""
positional_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help|help)
            usage
            exit 0
            ;;
        create|remove|rm|multi-remove|mrm|list|ls|prune)
            if [[ -n "$command" ]]; then
                echo "Error: multiple commands provided: ${command} and $1" >&2
                echo ""
                usage
                exit 1
            fi
            command="$1"
            shift
            ;;
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
        --branch)
            if [[ $# -lt 2 ]]; then
                echo "Error: --branch requires a branch name" >&2
                exit 1
            fi
            if [[ "$branch_provided" == "true" ]]; then
                echo "Error: --branch was provided more than once" >&2
                echo ""
                usage
                exit 1
            fi
            branch_name="$2"
            branch_provided="true"
            shift 2
            ;;
        --force|-f)
            force="true"
            shift
            ;;
        --)
            shift
            positional_args+=("$@")
            break
            ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            echo ""
            usage
            exit 1
            ;;
        *)
            positional_args+=("$1")
            shift
            ;;
    esac
done

if [[ -z "$command" ]]; then
    echo "Error: command is required" >&2
    echo ""
    usage
    exit 1
fi

if [[ "$dir_provided" != "true" ]]; then
    echo "Error: --dir <path> is required" >&2
    echo ""
    usage
    exit 1
fi

case "$command" in
    create|remove|rm)
        if [[ "$branch_provided" != "true" ]]; then
            echo "Error: --branch <name> is required for '${command}'" >&2
            echo ""
            usage
            exit 1
        fi
        if [[ ${#positional_args[@]} -gt 0 ]]; then
            echo "Error: unexpected argument(s): ${positional_args[*]}" >&2
            echo ""
            usage
            exit 1
        fi
        ;;
    multi-remove|mrm)
        if [[ "$branch_provided" == "true" ]]; then
            echo "Error: --branch is not valid for '${command}'; pass branch names as positional args" >&2
            echo ""
            usage
            exit 1
        fi
        if [[ ${#positional_args[@]} -eq 0 ]]; then
            echo "Error: '${command}' requires at least one branch name" >&2
            echo ""
            usage
            exit 1
        fi
        ;;
    list|ls|prune)
        if [[ "$branch_provided" == "true" ]]; then
            echo "Error: --branch is not valid for '${command}'" >&2
            echo ""
            usage
            exit 1
        fi
        if [[ ${#positional_args[@]} -gt 0 ]]; then
            echo "Error: unexpected argument(s): ${positional_args[*]}" >&2
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
        cmd_create "$branch_name" "$base_branch"
        ;;
    remove|rm)
        cmd_remove "$branch_name" "$force"
        ;;
    multi-remove|mrm)
        cmd_multi_remove "$force" "${positional_args[@]}"
        ;;
    list|ls)
        cmd_list
        ;;
    prune)
        cmd_prune
        ;;
esac
