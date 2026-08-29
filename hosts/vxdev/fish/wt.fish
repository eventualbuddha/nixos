function wt --description "Manage git worktrees for vxsuite"
    if test (count $argv) -eq 0
        __wt_help
        return 1
    end

    set -l cmd $argv[1]
    set -e argv[1]

    switch $cmd
        case add new
            __wt_add $argv

        case rm remove
            __wt_remove $argv

        case ls list
            __wt_list

        case cd
            __wt_cd $argv

        case status st
            __wt_status

        case help -h --help
            __wt_help

            # Private helpers for completions
        case __targets
            __wt_complete_targets

        case __branches
            __wt_complete_branches

        case '*'
            echo "wt: unknown command '$cmd'" >&2
            return 1
    end
end

function __wt_help
    echo "wt - manage git worktrees for vxsuite"
    echo ""
    echo "Usage: wt <command> [args]"
    echo ""
    echo "Commands:"
    echo "  add|new <branch> [-b|--branch <base>]  Create or check out a worktree for <branch>"
    echo "                                          If <branch> exists locally or on a remote, it is"
    echo "                                          checked out; otherwise it is created from <base>"
    echo "                                          (default: main)"
    echo "                                          Runs mise trust, pnpm install, and pnpm build"
    echo "                                          With --rebase, rebase on main before building"
    echo "                                          If a worktree already exists, just cd into it"
    echo "  rm|remove [name] [-f|--force]           Remove a worktree (defaults to current directory)"
    echo "                                          Fails if there are uncommitted or unpushed commits"
    echo "                                          Also deletes the associated branch"
    echo "  cd [name] [--rebase]                    cd into a worktree"
    echo "                                            cd            → main worktree (~/code/vxsuite)"
    echo "                                            cd main       → main worktree"
    echo "                                            cd -          → previous worktree"
    echo "                                            cd <name>     → worktree for that branch/folder"
    echo "                                          If <name> is a branch with no worktree, one is created"
    echo "                                          With --rebase, rebase on main and rebuild after"
    echo "                                          cd'ing; if the rebase fails, the cd still happens"
    echo "                                          but the build is skipped"
    echo "  ls|list                                 List all worktrees"
    echo "  status|st                               Show all worktrees with branch and dirty status"
    echo "  help                                    Show this help"
    echo ""
    echo "Worktrees are created at ~/code/vxsuite-<branch>, with slashes in the branch name"
    echo "replaced by dashes (branch brian/foo → ~/code/vxsuite-brian-foo)."
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function __wt_slug --description "Turn a branch name into a worktree directory name"
    string replace -a / - -- "$argv[1]"
end

function __wt_entries --description "Print 'path<TAB>branch' for every worktree"
    set -l main_tree ~/code/vxsuite
    set -l path ""
    set -l branch ""

    for line in (git -C "$main_tree" worktree list --porcelain 2>/dev/null)
        if string match -q 'worktree *' -- "$line"
            # Skip submodules' internal worktrees, they aren't ours to manage
            if test -n "$path"; and not string match -q '*/.git/*' -- "$path"
                printf '%s\t%s\n' "$path" "$branch"
            end
            set path (string replace 'worktree ' '' -- "$line")
            set branch ""
        else if string match -q 'branch refs/heads/*' -- "$line"
            set branch (string replace 'branch refs/heads/' '' -- "$line")
        end
    end

    if test -n "$path"; and not string match -q '*/.git/*' -- "$path"
        printf '%s\t%s\n' "$path" "$branch"
    end
end

function __wt_find --description "Resolve a branch name or folder name to a worktree path"
    set -l prefix ~/code/vxsuite-
    set -l query "$argv[1]"

    if test -z "$query"
        return 1
    end

    # Everything the user might reasonably have typed for a worktree.
    set -l slug (__wt_slug "$query")
    set -l queries "$query" "$slug" "vxsuite-$query" "vxsuite-$slug"

    for entry in (__wt_entries)
        set -l parts (string split -m1 \t -- "$entry")
        set -l path $parts[1]
        set -l branch $parts[2]

        set -l candidates "$path" (string replace -- "$prefix" "" "$path") (string replace -r '.*/' '' -- "$path")
        if test -n "$branch"
            set -a candidates "$branch"
        end

        for q in $queries
            if contains -- "$q" $candidates
                echo "$path"
                return 0
            end
        end
    end

    return 1
end

function __wt_containing --description "Print the registered worktree whose path contains DIR"
    set -l dir (realpath "$argv[1]" 2>/dev/null; or echo "$argv[1]")
    set -l best ""

    for entry in (__wt_entries)
        set -l parts (string split -m1 \t -- "$entry")
        set -l path (realpath "$parts[1]" 2>/dev/null; or echo "$parts[1]")

        if test "$dir" = "$path"; or string match -q "$path/*" -- "$dir"
            # Worktree paths can nest (~/code/vxsuite-brian/foo/bar), so keep the
            # deepest match rather than the first one that happens to contain us.
            if test (string length -- "$path") -gt (string length -- "$best")
                set best "$path"
            end
        end
    end

    if test -z "$best"
        return 1
    end

    echo "$best"
end

function __wt_local_branch --description "Succeed if BRANCH exists locally"
    git -C ~/code/vxsuite show-ref --verify --quiet "refs/heads/$argv[1]"
end

function __wt_remote_ref --description "Print <remote>/<branch> if an already-fetched remote branch exists"
    set -l main_tree ~/code/vxsuite
    set -l branch "$argv[1]"

    for remote in (git -C "$main_tree" remote)
        if git -C "$main_tree" show-ref --verify --quiet "refs/remotes/$remote/$branch"
            echo "$remote/$branch"
            return 0
        end
    end

    return 1
end

function __wt_fetch_branch --description "Look for BRANCH on the remotes, fetch it, print <remote>/<branch>"
    set -l main_tree ~/code/vxsuite
    set -l branch "$argv[1]"

    for remote in (git -C "$main_tree" remote)
        if git -C "$main_tree" ls-remote --exit-code --heads "$remote" "refs/heads/$branch" >/dev/null 2>&1
            echo "Fetching '$branch' from $remote..." >&2
            if git -C "$main_tree" fetch --quiet "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch"
                echo "$remote/$branch"
                return 0
            end
        end
    end

    return 1
end

function __wt_resolve_branch --description "Print <branch> or <remote>/<branch> if it exists anywhere, fetching if needed"
    set -l branch "$argv[1]"

    if __wt_local_branch "$branch"
        echo "$branch"
        return 0
    end

    set -l remote_ref (__wt_remote_ref "$branch")
    if test -z "$remote_ref"
        set remote_ref (__wt_fetch_branch "$branch")
    end

    if test -n "$remote_ref"
        echo "$remote_ref"
        return 0
    end

    return 1
end

function __wt_rebase_main --description "Rebase the worktree at PATH onto the latest main"
    set -l wt_path "$argv[1]"

    set -l branch (git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if test -z "$branch"; or test "$branch" = HEAD
        echo "wt: refusing to rebase the detached HEAD in $wt_path" >&2
        return 1
    end

    # Prefer the remote's main so the rebase picks up commits the local main
    # hasn't been updated to yet.
    set -l onto (__wt_fetch_branch main)
    if test -z "$onto"
        set onto (__wt_remote_ref main)
    end
    if test -z "$onto"; and __wt_local_branch main
        set onto main
    end
    if test -z "$onto"
        echo "wt: no main branch to rebase onto" >&2
        return 1
    end

    echo "Rebasing '$branch' onto $onto..."
    git -C "$wt_path" rebase "$onto"
end

function __wt_build --description "Install dependencies and build the worktree in the current directory"
    if type -q mise
        mise trust
    end

    pnpm install
    and pnpm build
end

function __wt_rebase_and_build --description "Rebase the worktree at PATH onto main and build it; PATH must be the current directory"
    __wt_rebase_main "$argv[1]"
    or begin
        echo "wt: rebase failed, skipping the build" >&2
        return 1
    end

    __wt_build
end

function __wt_goto --description "cd to a path, remembering where we came from"
    set -g __wt_last_dir (pwd)
    cd "$argv[1]"
end

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

function __wt_add
    set -l main_tree ~/code/vxsuite
    set -l prefix ~/code/vxsuite-
    set -l base_branch ""
    set -l name ""
    set -l rebase 0

    # Parse args
    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case --rebase
                set rebase 1
            case --branch -b
                set i (math $i + 1)
                if test $i -le (count $argv)
                    set base_branch $argv[$i]
                else
                    echo "wt add: --branch requires an argument" >&2
                    return 1
                end
            case '-*'
                echo "wt add: unknown option '$argv[$i]'" >&2
                return 1
            case '*'
                if test -z "$name"
                    set name $argv[$i]
                else
                    echo "wt add: unexpected argument '$argv[$i]'" >&2
                    return 1
                end
        end
        set i (math $i + 1)
    end

    if test -z "$name"
        echo "wt add: branch name required" >&2
        return 1
    end

    # Already have a worktree for this branch (or folder name)? Just go there.
    set -l existing (__wt_find "$name")
    if test -n "$existing"
        echo "Worktree for '$name' already exists at $existing"
        __wt_goto "$existing"
        or return 1

        if test $rebase -eq 1
            __wt_rebase_and_build "$existing"
            return $status
        end

        return 0
    end

    set -l wt_path "$prefix"(__wt_slug "$name")

    if test -e "$wt_path"
        echo "wt add: $wt_path already exists but is not a registered worktree" >&2
        return 1
    end

    # Decide what to check out: an existing local branch, an existing remote
    # branch, or a brand new branch off the base branch.
    set -l git_args
    if __wt_local_branch "$name"
        if test -n "$base_branch"
            echo "wt add: branch '$name' already exists, ignoring --branch $base_branch" >&2
        end
        echo "Checking out existing branch '$name' at $wt_path..."
        set git_args "$wt_path" "$name"
    else
        set -l remote_ref (__wt_remote_ref "$name")
        if test -z "$remote_ref"
            set remote_ref (__wt_fetch_branch "$name")
        end

        if test -n "$remote_ref"
            if test -n "$base_branch"
                echo "wt add: branch '$name' already exists on the remote, ignoring --branch $base_branch" >&2
            end
            echo "Checking out remote branch '$remote_ref' at $wt_path..."
            set git_args --track -b "$name" "$wt_path" "$remote_ref"
        else
            set -l base "$base_branch"
            if test -z "$base"
                set base main
            end

            set -l start (__wt_resolve_branch "$base")
            if test -z "$start"
                echo "wt add: base branch '$base' not found locally or on any remote" >&2
                return 1
            end

            echo "Creating branch '$name' from $start at $wt_path..."
            set git_args -b "$name" "$wt_path" "$start"
        end
    end

    git -C "$main_tree" worktree add $git_args
    or begin
        echo "wt add: failed to create worktree" >&2
        return 1
    end

    echo "Setting up worktree..."
    __wt_goto "$wt_path"
    or return 1

    if test $rebase -eq 1
        __wt_rebase_main "$wt_path"
        or begin
            echo "wt add: rebase failed, skipping the build (worktree still created)" >&2
            return 1
        end
    end

    __wt_build
    or begin
        echo "wt add: setup commands had errors (worktree still created)" >&2
        return 1
    end

    echo ""
    echo "Worktree for '$name' ready at $wt_path"
end

function __wt_remove
    set -l main_tree ~/code/vxsuite
    set -l prefix ~/code/vxsuite-
    set -l force 0
    set -l name ""

    # Parse args
    for arg in $argv
        switch $arg
            case --force -f
                set force 1
            case '-*'
                echo "wt rm: unknown option '$arg'" >&2
                return 1
            case '*'
                if test -z "$name"
                    set name $arg
                else
                    echo "wt rm: unexpected argument '$arg'" >&2
                    return 1
                end
        end
    end

    # Determine worktree path
    set -l wt_path ""
    if test -n "$name"
        set wt_path (__wt_find "$name")
        if test -z "$wt_path"
            echo "wt rm: no worktree matching '$name'" >&2
            return 1
        end
    else
        # Infer from PWD, which may be any directory inside the worktree
        set wt_path (__wt_containing (pwd))
        if test -z "$wt_path"
            echo "wt rm: '"(pwd)"' is not inside a vxsuite worktree" >&2
            return 1
        end
    end

    # Resolve to absolute path
    set wt_path (realpath "$wt_path" 2>/dev/null; or echo "$wt_path")
    set -l main_resolved (realpath "$main_tree")

    # Don't allow removing the main worktree
    if test "$wt_path" = "$main_resolved"
        echo "wt rm: refusing to remove the main worktree" >&2
        return 1
    end

    # Check it's actually a vxsuite worktree
    if not string match -q "$prefix*" "$wt_path"
        echo "wt rm: '$wt_path' is not a vxsuite worktree" >&2
        return 1
    end

    if not test -d "$wt_path"
        echo "wt rm: '$wt_path' does not exist" >&2
        return 1
    end

    set -l branch (git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Check for local changes unless --force
    if test $force -eq 0
        set -l dirty (git -C "$wt_path" status --porcelain 2>/dev/null)
        if test -n "$dirty"
            echo "wt rm: worktree has uncommitted changes:" >&2
            git -C "$wt_path" status --short >&2
            echo "" >&2
            echo "Use --force to remove anyway" >&2
            return 1
        end

        # Check for unpushed commits. Fall back to the default branch when the
        # branch has no upstream, so an unpushed branch isn't silently dropped.
        if test -n "$branch"; and test "$branch" != HEAD
            set -l base '@{upstream}'
            if not git -C "$wt_path" rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1
                set base (__wt_remote_ref main)
                if test -z "$base"
                    set base main
                end
            end

            set -l unpushed (git -C "$wt_path" log --oneline "$base..HEAD" 2>/dev/null)
            if test -n "$unpushed"
                echo "wt rm: worktree has commits on '$branch' not in $base:" >&2
                git -C "$wt_path" log --oneline "$base..HEAD" >&2
                echo "" >&2
                echo "Use --force to remove anyway" >&2
                return 1
            end
        end
    end

    set -l wt_name (string replace -- "$prefix" "" "$wt_path")
    echo "Removing worktree '$wt_name'..."

    # If we're inside the worktree being removed, cd out first
    set -l here (pwd)
    if test "$here" = "$wt_path"; or string match -q "$wt_path/*" "$here"
        __wt_goto "$main_tree"
        echo "Changed directory to $main_tree"
    end

    git -C "$main_tree" worktree remove "$wt_path" --force
    or begin
        echo "wt rm: failed to remove worktree" >&2
        return 1
    end

    # Clean up the branch too
    if test -n "$branch"; and test "$branch" != HEAD
        set -l delete_flag -d
        if test $force -eq 1
            set delete_flag -D
        end

        if git -C "$main_tree" branch $delete_flag "$branch" >/dev/null 2>&1
            echo "Deleted branch '$branch'"
        else
            echo "Kept branch '$branch' (not fully merged; delete with: git -C $main_tree branch -D $branch)"
        end
    end

    echo "Worktree '$wt_name' removed"
end

function __wt_list
    set -l main_tree ~/code/vxsuite
    echo "vxsuite worktrees:"
    echo ""
    git -C "$main_tree" worktree list
end

function __wt_cd
    set -l main_tree ~/code/vxsuite
    set -l rebase 0
    set -l name ""

    # Parse args
    for arg in $argv
        switch $arg
            case --rebase
                set rebase 1
            case -
                if test -z "$name"
                    set name $arg
                else
                    echo "wt cd: unexpected argument '$arg'" >&2
                    return 1
                end
            case '-*'
                echo "wt cd: unknown option '$arg'" >&2
                return 1
            case '*'
                if test -z "$name"
                    set name $arg
                else
                    echo "wt cd: unexpected argument '$arg'" >&2
                    return 1
                end
        end
    end

    if test -z "$name"; or test "$name" = main
        __wt_goto "$main_tree"
        or return 1

        if test $rebase -eq 1
            __wt_rebase_and_build "$main_tree"
            return $status
        end

        return 0
    end

    # Handle "wt cd -" to go back to the previous worktree
    if test "$name" = -
        if not set -q __wt_last_dir
            echo "wt cd: no previous worktree" >&2
            return 1
        end
        set -l prev $__wt_last_dir
        set -g __wt_last_dir (pwd)
        cd "$prev"
        or return 1

        if test $rebase -eq 1
            set -l wt_path (__wt_containing (pwd))
            if test -z "$wt_path"
                echo "wt cd: '"(pwd)"' is not inside a vxsuite worktree, skipping the rebase" >&2
                return 1
            end
            __wt_rebase_and_build "$wt_path"
            return $status
        end

        return 0
    end

    # A branch name, a folder basename, or a folder path all work here.
    set -l wt_path (__wt_find "$name")
    if test -n "$wt_path"
        __wt_goto "$wt_path"
        or return 1

        if test $rebase -eq 1
            __wt_rebase_and_build "$wt_path"
            return $status
        end

        return 0
    end

    # No worktree yet, but if it names a real branch we can make one.
    set -l branch_ref (__wt_resolve_branch "$name")
    if test -n "$branch_ref"
        echo "No worktree for branch '$name' yet, creating one..."
        if test $rebase -eq 1
            __wt_add --rebase "$name"
        else
            __wt_add "$name"
        end
        return $status
    end

    echo "wt cd: no worktree or branch matching '$name'" >&2
    echo "Available worktrees:" >&2
    __wt_list >&2
    return 1
end

function __wt_status
    set -l main_tree ~/code/vxsuite
    set -l code_dir (realpath ~/code)"/"

    for entry in (__wt_entries)
        set -l parts (string split -m1 \t -- "$entry")
        set -l wt_path $parts[1]
        set -l branch $parts[2]

        set -l display_name (string replace -- "$code_dir" "" "$wt_path")
        if test -z "$branch"
            set branch (git -C "$wt_path" rev-parse --short HEAD 2>/dev/null)" (detached)"
        end

        set -l dirty ""
        set -l changes (git -C "$wt_path" status --porcelain 2>/dev/null)
        if test -n "$changes"
            set dirty " [dirty]"
        end

        echo "$display_name ($branch)$dirty"
    end
end

# ---------------------------------------------------------------------------
# Completion helpers (invoked as `wt __targets` / `wt __branches`)
# ---------------------------------------------------------------------------

function __wt_complete_targets --description "Print 'name<TAB>description' for every worktree"
    set -l main_tree (realpath ~/code/vxsuite)
    set -l prefix ~/code/vxsuite-

    for entry in (__wt_entries)
        set -l parts (string split -m1 \t -- "$entry")
        set -l wt_path $parts[1]
        set -l branch $parts[2]

        if test (realpath "$wt_path" 2>/dev/null; or echo "$wt_path") = "$main_tree"
            printf '%s\t%s\n' main "main worktree"
            if test -n "$branch"; and test "$branch" != main
                printf '%s\t%s\n' "$branch" "main worktree"
            end
            continue
        end

        if not string match -q "$prefix*" "$wt_path"
            continue
        end

        set -l rel (string replace -- "$prefix" "" "$wt_path")

        if test -n "$branch"
            printf '%s\t%s\n' "$branch" "worktree $rel"
        end

        if test "$rel" != "$branch"
            if test -n "$branch"
                printf '%s\t%s\n' "$rel" "branch $branch"
            else
                printf '%s\t%s\n' "$rel" worktree
            end
        end
    end
end

function __wt_complete_branches --description "Print 'branch<TAB>description' for local and remote branches"
    set -l main_tree ~/code/vxsuite
    set -l seen

    for branch in (git -C "$main_tree" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
        set -a seen "$branch"
        printf '%s\t%s\n' "$branch" "local branch"
    end

    for remote in (git -C "$main_tree" remote)
        for ref in (git -C "$main_tree" for-each-ref --format='%(refname:short)' "refs/remotes/$remote" 2>/dev/null)
            set -l branch (string replace -- "$remote/" "" "$ref")
            if test "$branch" = HEAD
                continue
            end
            if contains -- "$branch" $seen
                continue
            end
            set -a seen "$branch"
            printf '%s\t%s\n' "$branch" "$remote branch"
        end
    end
end
