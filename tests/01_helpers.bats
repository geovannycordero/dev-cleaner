#!/usr/bin/env bats
# Characterization tests: lock in existing helper behaviour before refactoring.
# shellcheck disable=SC2034  # DRY_RUN etc. are read by the sourced functions

load test_helper

@test "human_kb uses binary units like df -h" {
    [ "$(human_kb 0)" = "0Ki" ]
    [ "$(human_kb 512)" = "512Ki" ]
    [ "$(human_kb 1536)" = "1.5Mi" ]
    [ "$(human_kb 1048576)" = "1.0Gi" ]
}

@test "du_kb_sum sums paths and globs, ignoring missing ones" {
    make_file "$HOME/a/one" 64
    make_file "$HOME/a/two" 64
    local expected
    expected=$(( $(du -sk "$HOME/a/one" | awk '{print $1}') + $(du -sk "$HOME/a/two" | awk '{print $1}') ))
    [ "$(du_kb_sum "$HOME/a/"* "$HOME/missing")" -eq "$expected" ]
    [ "$(du_kb_sum "$HOME/missing")" -eq 0 ]
}

@test "safe_rm under dry-run keeps the path and credits its size" {
    make_file "$HOME/cache/blob" 64
    DRY_RUN=true
    RECLAIMED_KB=0
    safe_rm -r "$HOME/cache" > "$BATS_TEST_TMPDIR/out.txt"
    [ -d "$HOME/cache" ]
    [ "$RECLAIMED_KB" -ge 64 ]
    grep -q "\[DRY-RUN\] Would delete directory: $HOME/cache" "$BATS_TEST_TMPDIR/out.txt"
}

@test "safe_rm deletes and credits its size" {
    make_file "$HOME/cache/blob" 64
    DRY_RUN=false
    RECLAIMED_KB=0
    safe_rm -r "$HOME/cache"
    [ ! -e "$HOME/cache" ]
    [ "$RECLAIMED_KB" -ge 64 ]
}

@test "safe_rm expands globs and skips non-matching ones" {
    make_file "$HOME/cache/a" 4
    make_file "$HOME/cache/b" 4
    DRY_RUN=false
    safe_rm -rf "$HOME/cache/"* "$HOME/nothing/"*
    [ -d "$HOME/cache" ]
    [ -z "$(ls -A "$HOME/cache")" ]
}

@test "tracked_run under dry-run announces the command without running it" {
    make_file "$HOME/npmcache/blob" 64
    DRY_RUN=true
    RECLAIMED_KB=0
    run tracked_run "$HOME/npmcache" -- npm cache clean --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] Would run: npm cache clean --force"* ]] || false
    [ ! -s "$STUB_LOG" ]
}

@test "tracked_run runs the command when not in dry-run" {
    DRY_RUN=false
    tracked_run "$HOME/npmcache" -- npm cache clean --force
    grep -qx "npm cache clean --force" "$STUB_LOG"
}

@test "claude_removable_versions keeps the version the launcher points at" {
    mkdir -p "$CLAUDE_VERSIONS_DIR" "$(dirname "$CLAUDE_LAUNCHER")"
    touch "$CLAUDE_VERSIONS_DIR/1.0.0" "$CLAUDE_VERSIONS_DIR/2.0.0"
    ln -s "$CLAUDE_VERSIONS_DIR/2.0.0" "$CLAUDE_LAUNCHER"
    run claude_removable_versions
    [ "$status" -eq 0 ]
    [ "$output" = "$CLAUDE_VERSIONS_DIR/1.0.0" ]
}

@test "claude_removable_versions refuses when the launcher is not a symlink" {
    mkdir -p "$CLAUDE_VERSIONS_DIR" "$(dirname "$CLAUDE_LAUNCHER")"
    touch "$CLAUDE_VERSIONS_DIR/1.0.0" "$CLAUDE_LAUNCHER"
    run claude_removable_versions
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "claude_removable_versions reports Claude Code as not installed" {
    run claude_removable_versions
    [ "$status" -eq 1 ]
}
