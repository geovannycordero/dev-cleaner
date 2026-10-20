#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2329  # globals/overrides are used by the sourced functions

load test_helper

node_project() {
    make_file "$HOME/repos/web/package.json" 1
    make_file "$HOME/repos/web/node_modules/x/index.js" 16
}

@test "--only runs the selected cleanups without a terminal in dry-run" {
    make_file "$HOME/Library/Caches/ms-playwright/chromium/chrome" 16
    run bash "$SCRIPT" --only nuget,playwright --dry-run < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would run: dotnet nuget locals all --clear"* ]] || false
    [[ "$output" == *"Would delete directory: $HOME/Library/Caches/ms-playwright/chromium"* ]] || false
    [[ "$output" == *"Would reclaim"* ]] || false
    [ -f "$HOME/Library/Caches/ms-playwright/chromium/chrome" ]
}

@test "--only rejects unknown keys and lists the valid ones" {
    run bash "$SCRIPT" --only node_modules,foo --dry-run < /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"Unknown cleanup: foo"* ]] || false
    [[ "$output" == *"worktrees"* ]] || false
}

@test "--only refuses to delete without a terminal unless --yes is given" {
    node_project
    run bash "$SCRIPT" --only node_modules --projects-dir "$HOME/repos" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"--yes"* ]] || false
    [ -d "$HOME/repos/web/node_modules" ]
}

@test "--only with --yes deletes and reports what was reclaimed" {
    node_project
    run bash "$SCRIPT" --only node_modules --projects-dir "$HOME/repos" --yes < /dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/repos/web/node_modules" ]
    [[ "$output" == *"Reclaimed"* ]] || false
}

@test "--only asks for sudo only when a selected cleanup needs it" {
    run bash "$SCRIPT" --only npm --yes < /dev/null
    run ! grep -q "^sudo -v" "$STUB_LOG"
    run bash "$SCRIPT" --only timemachine --yes < /dev/null
    grep -q "^sudo -v" "$STUB_LOG"
}

@test "--only without a value is an error" {
    run bash "$SCRIPT" --only
    [ "$status" -eq 1 ]
}

@test "menu option 20 cleans node_modules" {
    node_project
    run bash "$SCRIPT" --projects-dir "$HOME/repos" <<< $'y\n20\n\n0\n'
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/repos/web/node_modules" ]
}

@test "menu options 21-23 dispatch to their cleanups" {
    run bash "$SCRIPT" --dry-run <<< $'y\n21\n\n22\n\n23\n\n0\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Performing .NET Build Output Cleanup"* ]] || false
    [[ "$output" == *"Performing Playwright Cleanup"* ]] || false
    [[ "$output" == *"Performing Worktree Cleanup"* ]] || false
    [[ "$output" != *"Invalid choice"* ]] || false
}

@test "the menu lists the new options and the full range" {
    run bash "$SCRIPT" --dry-run <<< $'y\n0\n'
    [[ "$output" == *"20."*"node_modules"* ]] || false
    [[ "$output" == *"23."*"worktrees"* ]] || false
    [[ "$output" == *"(0-23"* ]] || false
}

@test "Clear All runs project cleanups and Playwright but never worktrees" {
    run_cleanup() { echo "ran $1"; }
    PROJECTS_DIR_SOURCE="command-line"
    run clear_all
    [[ "$output" == *"ran node_modules"* ]] || false
    [[ "$output" == *"ran dotnet"* ]] || false
    [[ "$output" == *"ran playwright"* ]] || false
    [[ "$output" == *"ran xcode"* ]] || false
    [[ "$output" != *"ran worktrees"* ]] || false
}

@test "Clear All skips project cleanups when only the default root is set" {
    run_cleanup() { echo "ran $1"; }
    PROJECTS_DIR_SOURCE="default"
    run clear_all
    [[ "$output" != *"ran node_modules"* ]] || false
    [[ "$output" != *"ran dotnet"* ]] || false
    [[ "$output" == *"--projects-dir"* ]] || false
    [[ "$output" == *"ran playwright"* ]] || false
}

@test "every --only key has a cleanup and every estimate key is a cleanup key" {
    local key
    for key in $CLEANUP_KEYS; do
        grep -qE "^ +${key}\) " "$SCRIPT"
    done
    while IFS= read -r key; do
        [ "$key" = "total" ] && continue
        [[ " $CLEANUP_KEYS " == *" $key "* ]] || false
    done < <(grep -oE 'set_estimate [a-z_]+' "$SCRIPT" | awk '{print $2}' | sort -u)
}

@test "--help documents the new flags and keys; version is 1.3.0" {
    run bash "$SCRIPT" --help
    [[ "$output" == *"--projects-dir"* ]] || false
    [[ "$output" == *"--only"* ]] || false
    [[ "$output" == *"--yes"* ]] || false
    [[ "$output" == *"DEV_CLEANER_PROJECT_DIRS"* ]] || false
    [[ "$output" == *"worktrees"* ]] || false
    run bash "$SCRIPT" --version
    [[ "$output" == *"v1.3.0"* ]] || false
}
