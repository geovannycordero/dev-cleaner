#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2329  # globals/overrides are used by the sourced functions

load test_helper

# Fake gh: auth succeeds, `pr list` answers from $STUB_OUT_DIR/pr-<branch>
# (written by pr_is), NONE otherwise. Defined as a function so it beats the
# PATH stub and can answer per branch.
gh() {
    case "$1 $2" in
        "auth status") return 0 ;;
        "pr list")
            local branch file
            branch="$(echo "$*" | sed -E 's/.*--head ([^ ]+).*/\1/')"
            file="$STUB_OUT_DIR/pr-$(echo "$branch" | tr '/' '_')"
            if [ -f "$file" ]; then cat "$file"; else echo NONE; fi
            ;;
    esac
}
pr_is() { echo "$2" > "$STUB_OUT_DIR/pr-$(echo "$1" | tr '/' '_')"; }

git_repo() {
    git init -q -b main "$1"
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name Test
    git -C "$1" config commit.gpgsign false
    git -C "$1" commit -q --allow-empty -m init
    git -C "$1" remote add origin "${2:-git@github.com:acme/app.git}"
}

setup_worktrees() {
    R="$HOME/repos"
    git_repo "$R/app"
    git -C "$R/app" worktree add -q -b T-1/merged "$R/worksets/T-1/app"
    resolve_project_roots "$R"
    R="${PROJECT_ROOTS[0]}"
    WT="$R/worksets/T-1/app"
}

@test "github_slug parses ssh, https and ssh:// remotes" {
    [ "$(github_slug git@github.com:acme/app.git)" = "acme/app" ]
    [ "$(github_slug https://github.com/acme/app.git)" = "acme/app" ]
    [ "$(github_slug https://github.com/acme/app)" = "acme/app" ]
    [ "$(github_slug https://user@github.com/acme/app.git)" = "acme/app" ]
    [ "$(github_slug ssh://git@github.com/acme/app.git)" = "acme/app" ]
    [ -z "$(github_slug git@gitlab.com:acme/app.git)" ]
    [ -z "$(github_slug "")" ]
}

@test "list_worktrees finds linked worktrees inside and outside the roots" {
    setup_worktrees
    mkdir -p "$HOME/elsewhere"
    git -C "$R/app" worktree add -q -b outside "$HOME/elsewhere/wt"
    run list_worktrees "$R"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
    [[ "$output" == *"$R/app"$'\t'"$WT"$'\t'"T-1/merged"* ]] || false
    [[ "$output" == *$'\t'"T-1/merged"* ]] || false
    [[ "$output" == *$'\t'"outside"* ]] || false
    [[ "$output" != *$'\t'"main"* ]] || false
}

@test "list_worktrees skips detached and locked worktrees" {
    setup_worktrees
    git -C "$R/app" worktree add -q --detach "$R/worksets/T-2/app"
    git -C "$R/app" worktree add -q -b locked-one "$R/worksets/T-3/app"
    git -C "$R/app" worktree lock "$R/worksets/T-3/app"
    run list_worktrees "$R"
    [ "$output" = "$R/app"$'\t'"$WT"$'\t'"T-1/merged" ]
}

@test "pr_state reports the PR state, NONE without a PR" {
    pr_is T-1/merged MERGED
    [ "$(pr_state acme/app T-1/merged)" = "MERGED" ]
    [ "$(pr_state acme/app no-pr)" = "NONE" ]
}

@test "pr_state reports UNKNOWN when gh fails" {
    gh() { return 1; }
    [ "$(pr_state acme/app x)" = "UNKNOWN" ]
}

@test "worktree_action maps PR state and dirtiness to an action" {
    [ "$(worktree_action MERGED false)" = "remove" ]
    [ "$(worktree_action CLOSED false)" = "warn" ]
    [ "$(worktree_action OPEN false)" = "skip" ]
    [ "$(worktree_action NONE false)" = "skip" ]
    [ "$(worktree_action UNKNOWN false)" = "skip" ]
    [ "$(worktree_action MERGED true)" = "skip-dirty" ]
}

@test "a merged worktree is removed with its branch after confirmation" {
    setup_worktrees
    pr_is T-1/merged MERGED
    DRY_RUN=false
    run cleanup_worktrees <<< "y"
    [ "$status" -eq 0 ]
    [ ! -e "$WT" ]
    [ -z "$(git -C "$R/app" branch --list T-1/merged)" ]
    [[ "$output" == *"1 removed"* ]] || false
}

@test "answering no keeps the worktree" {
    setup_worktrees
    pr_is T-1/merged MERGED
    DRY_RUN=false
    run cleanup_worktrees <<< "n"
    [ -d "$WT" ]
}

@test "--yes removes merged worktrees without asking" {
    setup_worktrees
    pr_is T-1/merged MERGED
    DRY_RUN=false
    ASSUME_YES=true
    run cleanup_worktrees < /dev/null
    [ ! -e "$WT" ]
}

@test "--yes does not remove CLOSED worktrees; an explicit yes does" {
    setup_worktrees
    pr_is T-1/merged CLOSED
    DRY_RUN=false
    ASSUME_YES=true
    run cleanup_worktrees < /dev/null
    [ -d "$WT" ]
    ASSUME_YES=false
    run cleanup_worktrees <<< "y"
    [[ "$output" == *"CLOSED without merging"* ]] || false
    [ ! -e "$WT" ]
}

@test "open, PR-less and non-GitHub worktrees are never offered" {
    setup_worktrees
    pr_is T-1/merged OPEN
    git -C "$R/app" worktree add -q -b no-pr "$R/worksets/T-2/app"
    git_repo "$R/gl" git@gitlab.com:acme/gl.git
    git -C "$R/gl" worktree add -q -b T-1/merged "$R/worksets/T-1/gl"
    DRY_RUN=false
    ASSUME_YES=true
    run cleanup_worktrees <<< "y"
    [ -d "$WT" ]
    [ -d "$R/worksets/T-2/app" ]
    [ -d "$R/worksets/T-1/gl" ]
}

@test "a worktree with uncommitted changes is never offered, even with --yes" {
    setup_worktrees
    pr_is T-1/merged MERGED
    echo wip > "$WT/notes.txt"
    DRY_RUN=false
    ASSUME_YES=true
    run cleanup_worktrees <<< "y"
    [ -f "$WT/notes.txt" ]
    [[ "$output" == *"skip-dirty"* ]] || false
}

@test "an unmerged branch is kept and reported, the worktree still counts" {
    setup_worktrees
    pr_is T-1/merged MERGED
    git -C "$WT" commit -q --allow-empty -m "squash-merged upstream"
    DRY_RUN=false
    run cleanup_worktrees <<< "y"
    [ ! -e "$WT" ]
    [ -n "$(git -C "$R/app" branch --list T-1/merged)" ]
    [[ "$output" == *"Kept branch T-1/merged"* ]] || false
    [[ "$output" == *"1 removed"* ]] || false
}

lock_worktree_files() {
    mkdir -p "$WT/sub"
    echo x > "$WT/sub/f"
    git -C "$WT" add sub/f
    git -C "$WT" commit -q -m "add sub"
    chmod 555 "$WT/sub"
}

@test "--yes never forces a failed removal" {
    setup_worktrees
    pr_is T-1/merged MERGED
    lock_worktree_files
    DRY_RUN=false
    ASSUME_YES=true
    run cleanup_worktrees < /dev/null
    chmod -R 755 "$WT" 2>/dev/null || true
    [[ "$output" != *"Force removal"* ]] || false
    [[ "$output" == *"not forced"* ]] || false
    [[ "$output" == *"1 failed"* ]] || false
}

@test "a failed removal asks before forcing" {
    setup_worktrees
    pr_is T-1/merged MERGED
    lock_worktree_files
    DRY_RUN=false
    run cleanup_worktrees <<< $'y\nn'
    chmod -R 755 "$WT" 2>/dev/null || true
    [[ "$output" == *"Force removal"* ]] || false
    [[ "$output" == *"1 failed"* ]] || false
}

@test "an emptied parent folder is removed, one with other files is kept" {
    setup_worktrees
    pr_is T-1/merged MERGED
    git -C "$R/app" worktree add -q -b T-2/merged "$R/worksets/T-2/app"
    pr_is T-2/merged MERGED
    echo "ticket" > "$R/worksets/T-2/ticket.md"
    DRY_RUN=false
    ASSUME_YES=true
    run cleanup_worktrees < /dev/null
    [ ! -e "$R/worksets/T-1" ]
    [ -f "$R/worksets/T-2/ticket.md" ]
    [ ! -e "$R/worksets/T-2/app" ]
}

@test "a project root is never removed as an empty parent" {
    git_repo "$HOME/main"
    mkdir -p "$HOME/wts"
    git -C "$HOME/main" worktree add -q -b T-1/merged "$HOME/wts/app"
    pr_is T-1/merged MERGED
    resolve_project_roots "$HOME/main" "$HOME/wts"
    DRY_RUN=false
    ASSUME_YES=true
    run cleanup_worktrees < /dev/null
    [ ! -e "$HOME/wts/app" ]
    [ -d "$HOME/wts" ]
}

@test "without an authenticated gh nothing is touched" {
    setup_worktrees
    gh() { return 1; }
    DRY_RUN=false
    ASSUME_YES=true
    run cleanup_worktrees < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping"* ]] || false
    [ -d "$WT" ]
}

@test "dry-run lists candidates and removes nothing" {
    setup_worktrees
    pr_is T-1/merged MERGED
    DRY_RUN=true
    RECLAIMED_KB=0
    cleanup_worktrees < /dev/null > "$BATS_TEST_TMPDIR/out.txt"
    [ -d "$WT" ]
    [ -n "$(git -C "$R/app" branch --list T-1/merged)" ]
    grep -q "Would remove worktree: $WT" "$BATS_TEST_TMPDIR/out.txt"
    [ "$RECLAIMED_KB" -gt 0 ]
}

@test "removed worktrees credit the reclaimed total" {
    setup_worktrees
    pr_is T-1/merged MERGED
    # Ignored build output (the usual bulk of a worktree) does not make it dirty
    echo node_modules >> "$R/app/.git/info/exclude"
    make_file "$WT/node_modules/big" 64
    DRY_RUN=false
    ASSUME_YES=true
    RECLAIMED_KB=0
    cleanup_worktrees < /dev/null > /dev/null
    [ ! -e "$WT" ]
    [ "$RECLAIMED_KB" -ge 64 ]
}

@test "estimate_all counts worktree candidates" {
    setup_worktrees
    pr_is T-1/merged MERGED
    estimate_all > /dev/null || true
    [ "$EST_worktrees_LABEL" = "~1 candidate(s)" ]
}
