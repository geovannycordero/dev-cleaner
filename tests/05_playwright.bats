#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2329  # globals/overrides are used by the sourced functions

load test_helper

@test "playwright cache lives in ~/Library/Caches on macOS" {
    uname() { echo Darwin; }
    unset PLAYWRIGHT_BROWSERS_PATH
    [ "$(playwright_cache_dir)" = "$HOME/Library/Caches/ms-playwright" ]
}

@test "playwright cache lives in XDG cache on Linux" {
    uname() { echo Linux; }
    unset PLAYWRIGHT_BROWSERS_PATH XDG_CACHE_HOME
    [ "$(playwright_cache_dir)" = "$HOME/.cache/ms-playwright" ]
    XDG_CACHE_HOME="$HOME/xdg"
    [ "$(playwright_cache_dir)" = "$HOME/xdg/ms-playwright" ]
}

@test "PLAYWRIGHT_BROWSERS_PATH overrides the default location" {
    PLAYWRIGHT_BROWSERS_PATH="$HOME/pw"
    [ "$(playwright_cache_dir)" = "$HOME/pw" ]
    # 0 means "inside node_modules", which the node_modules target covers
    PLAYWRIGHT_BROWSERS_PATH=0
    [ -z "$(playwright_cache_dir)" ]
}

@test "cleanup_playwright empties the cache dir and credits space" {
    unset PLAYWRIGHT_BROWSERS_PATH
    local dir
    dir="$(playwright_cache_dir)"
    make_file "$dir/chromium-1140/chrome" 32
    make_file "$dir/firefox-1465/firefox" 32
    DRY_RUN=false
    RECLAIMED_KB=0
    cleanup_playwright > /dev/null
    [ -d "$dir" ]
    [ -z "$(ls -A "$dir")" ]
    [ "$RECLAIMED_KB" -ge 64 ]
}

@test "cleanup_playwright under dry-run deletes nothing" {
    unset PLAYWRIGHT_BROWSERS_PATH
    local dir
    dir="$(playwright_cache_dir)"
    make_file "$dir/chromium-1140/chrome" 32
    DRY_RUN=true
    run cleanup_playwright
    [ -f "$dir/chromium-1140/chrome" ]
    [[ "$output" == *"Would delete directory: $dir/chromium-1140"* ]]
}

@test "cleanup_playwright skips when there is no cache" {
    unset PLAYWRIGHT_BROWSERS_PATH
    run cleanup_playwright
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping"* ]]
}

@test "estimate_all measures the playwright cache" {
    unset PLAYWRIGHT_BROWSERS_PATH
    make_file "$(playwright_cache_dir)/chromium-1140/chrome" 32
    estimate_all > /dev/null || true
    [ -n "$EST_playwright_LABEL" ]
    [ "$EST_playwright_LABEL" != "0Ki" ]
}
