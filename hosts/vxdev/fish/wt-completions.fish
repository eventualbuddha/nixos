# Completions for wt (vxsuite worktree manager)
#
# The candidate lists come from `wt __targets` / `wt __branches` so this file
# stays in sync with the function itself.

function __wt_needs_command
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

function __wt_using_command
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 2; and test "$cmd[2]" = "$argv[1]"
end

function __wt_using_command_any
    set -l cmd (commandline -opc)
    if test (count $cmd) -lt 2
        return 1
    end
    for subcmd in $argv
        if test "$cmd[2]" = "$subcmd"
            return 0
        end
    end
    return 1
end

# Subcommands
complete -c wt -f
complete -c wt -n __wt_needs_command -a add -d "Create or check out a worktree"
complete -c wt -n __wt_needs_command -a new -d "Create or check out a worktree"
complete -c wt -n __wt_needs_command -a rm -d "Remove a worktree"
complete -c wt -n __wt_needs_command -a remove -d "Remove a worktree"
complete -c wt -n __wt_needs_command -a ls -d "List all worktrees"
complete -c wt -n __wt_needs_command -a list -d "List all worktrees"
complete -c wt -n __wt_needs_command -a cd -d "Change to a worktree"
complete -c wt -n __wt_needs_command -a status -d "Show status of all worktrees"
complete -c wt -n __wt_needs_command -a st -d "Show status of all worktrees"
complete -c wt -n __wt_needs_command -a help -d "Show help"

# add/new — any existing branch can be checked out, so complete branches
complete -c wt -n '__wt_using_command_any add new' -a '(wt __branches)'
complete -c wt -n '__wt_using_command_any add new' -l branch -s b -d "Base branch for a new branch (default: main)" -x -a '(wt __branches)'
complete -c wt -n '__wt_using_command_any add new' -l rebase -d "Rebase on main before building"

# rm/remove — complete existing worktrees
complete -c wt -n '__wt_using_command_any rm remove' -a '(wt __targets)'
complete -c wt -n '__wt_using_command_any rm remove' -l force -s f -d "Force removal even with changes"

# cd — existing worktrees first, then any other branch, plus special targets
complete -c wt -n '__wt_using_command cd' -a '(wt __targets)'
complete -c wt -n '__wt_using_command cd' -a - -d "Previous worktree"
complete -c wt -n '__wt_using_command cd' -a '(wt __branches)'
complete -c wt -n '__wt_using_command cd' -l rebase -d "Rebase on main and rebuild after cd'ing"
