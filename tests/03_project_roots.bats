#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals are read by the sourced functions

load test_helper

real() { (cd "$1" && pwd -P); }

@test "project roots default to the current directory" {
    unset DEV_CLEANER_PROJECT_DIRS
    cd "$HOME"
    resolve_project_roots
    [ "${#PROJECT_ROOTS[@]}" -eq 1 ]
    [ "${PROJECT_ROOTS[0]}" = "$(real "$HOME")" ]
    [ "$PROJECTS_DIR_SOURCE" = "default" ]
}

@test "DEV_CLEANER_PROJECT_DIRS is a colon-separated list with ~ expansion" {
    mkdir -p "$HOME/repos" "$HOME/work"
    # shellcheck disable=SC2088  # literal ~ on purpose: the script must expand it
    DEV_CLEANER_PROJECT_DIRS="~/repos:$HOME/work"
    resolve_project_roots
    [ "${#PROJECT_ROOTS[@]}" -eq 2 ]
    [ "${PROJECT_ROOTS[0]}" = "$(real "$HOME/repos")" ]
    [ "${PROJECT_ROOTS[1]}" = "$(real "$HOME/work")" ]
    [ "$PROJECTS_DIR_SOURCE" = "environment" ]
}

@test "missing roots from the environment are dropped with a warning" {
    mkdir -p "$HOME/repos"
    DEV_CLEANER_PROJECT_DIRS="$HOME/repos:$HOME/nope"
    resolve_project_roots 2> "$BATS_TEST_TMPDIR/err"
    [ "${#PROJECT_ROOTS[@]}" -eq 1 ]
    grep -q "nope" "$BATS_TEST_TMPDIR/err"
}

@test "explicit dirs override the environment" {
    mkdir -p "$HOME/repos" "$HOME/cli"
    DEV_CLEANER_PROJECT_DIRS="$HOME/repos"
    resolve_project_roots "$HOME/cli"
    [ "${#PROJECT_ROOTS[@]}" -eq 1 ]
    [ "${PROJECT_ROOTS[0]}" = "$(real "$HOME/cli")" ]
    [ "$PROJECTS_DIR_SOURCE" = "command-line" ]
}

@test "nested and duplicate roots are dropped" {
    mkdir -p "$HOME/repos/worksets" "$HOME/other"
    resolve_project_roots "$HOME/repos/worksets" "$HOME/repos" "$HOME/other" "$HOME/repos"
    [ "${#PROJECT_ROOTS[@]}" -eq 2 ]
    [ "${PROJECT_ROOTS[0]}" = "$(real "$HOME/repos")" ]
    [ "${PROJECT_ROOTS[1]}" = "$(real "$HOME/other")" ]
}

@test "a sibling with a shared name prefix is not treated as nested" {
    mkdir -p "$HOME/repos" "$HOME/repos-old"
    resolve_project_roots "$HOME/repos" "$HOME/repos-old"
    [ "${#PROJECT_ROOTS[@]}" -eq 2 ]
}

@test "roots with spaces are kept intact" {
    mkdir -p "$HOME/my projects"
    resolve_project_roots "$HOME/my projects"
    [ "${PROJECT_ROOTS[0]}" = "$(real "$HOME/my projects")" ]
}

@test "--projects-dir is repeatable and reported at startup" {
    mkdir -p "$HOME/a" "$HOME/b"
    run bash -c "echo n | bash '$SCRIPT' --projects-dir '$HOME/a' --projects-dir '$HOME/b'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Project directories:"* ]]
    [[ "$output" == *"$(real "$HOME/a")"* ]]
    [[ "$output" == *"$(real "$HOME/b")"* ]]
    [[ "$output" == *"--projects-dir"* ]]
}

@test "--projects-dir with a missing directory is an error" {
    run bash "$SCRIPT" --projects-dir "$HOME/nope"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "--projects-dir without a value is an error" {
    run bash "$SCRIPT" --projects-dir
    [ "$status" -eq 1 ]
}
