#!/usr/bin/env bats
# shellcheck disable=SC2034  # DRY_RUN etc. are read by the sourced functions

load test_helper

@test "safe_rm refuses empty, root and HOME paths" {
    make_file "$HOME/keep" 4
    DRY_RUN=false
    for p in "" "/" "$HOME" "$HOME/"; do
        run safe_rm -rf "$p"
        [ "$status" -ne 0 ]
        [[ "$output" == *"Refusing"* ]] || false
    done
    [ -f "$HOME/keep" ]
}

@test "safe_sudo_rm refuses empty, root and HOME paths" {
    DRY_RUN=false
    for p in "" "/" "$HOME"; do
        run safe_sudo_rm -rf "$p"
        [ "$status" -ne 0 ]
    done
    run ! grep -q "rm" "$STUB_LOG"
}

@test "safe_rm treats a leading dash as a path, not an option" {
    mkdir -p "$HOME/work"
    make_file "$HOME/work/-n" 4
    cd "$HOME/work"
    DRY_RUN=false
    safe_rm "-n"
    [ ! -e "$HOME/work/-n" ]
}

@test "safe_rm returns non-zero when a delete fails and keeps going" {
    mkdir -p "$HOME/locked/inner" "$HOME/free"
    make_file "$HOME/locked/inner/f" 4
    make_file "$HOME/free/f" 4
    chmod 555 "$HOME/locked"
    DRY_RUN=false
    run safe_rm -r "$HOME/locked/inner" "$HOME/free"
    chmod 755 "$HOME/locked"
    [ "$status" -ne 0 ]
    [ ! -e "$HOME/free" ]
}

@test "safe_rm returns zero when everything was deleted" {
    make_file "$HOME/x/f" 4
    DRY_RUN=false
    run safe_rm -r "$HOME/x"
    [ "$status" -eq 0 ]
}

@test "cleanup_platformIO under dry-run does not run pio" {
    make_file "$HOME/proj/platformio.ini" 1
    DRY_RUN=true
    run cleanup_platformIO
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] Would run: "*"pio run -t clean -d $HOME/proj"* ]] || false
    run ! grep -q "^pio" "$STUB_LOG"
}

@test "cleanup_platformIO runs pio clean when not in dry-run" {
    make_file "$HOME/proj/platformio.ini" 1
    DRY_RUN=false
    run cleanup_platformIO
    grep -qx "pio run -t clean -d $HOME/proj" "$STUB_LOG"
}

make_build_tools() {
    local bt="$HOME/Library/Android/sdk/build-tools"
    make_file "$bt/30.0.0/aapt" 16
    make_file "$bt/31.0.0/aapt" 16
    make_file "$bt/32.0.0/aapt" 16
    touch -t 202001010000 "$bt/30.0.0"
    touch -t 202101010000 "$bt/31.0.0"
    touch -t 202201010000 "$bt/32.0.0"
}

@test "cleanup_android_sdk keeps the 2 newest build-tools, credits space and keeps PWD" {
    make_build_tools
    local before="$PWD"
    DRY_RUN=false
    RECLAIMED_KB=0
    cleanup_android_sdk > /dev/null
    [ "$PWD" = "$before" ]
    [ ! -e "$HOME/Library/Android/sdk/build-tools/30.0.0" ]
    [ -d "$HOME/Library/Android/sdk/build-tools/31.0.0" ]
    [ -d "$HOME/Library/Android/sdk/build-tools/32.0.0" ]
    [ "$RECLAIMED_KB" -ge 16 ]
}

@test "cleanup_android_sdk under dry-run deletes nothing" {
    make_build_tools
    DRY_RUN=true
    run cleanup_android_sdk
    [ -d "$HOME/Library/Android/sdk/build-tools/30.0.0" ]
    [[ "$output" == *"Would delete directory: $HOME/Library/Android/sdk/build-tools/30.0.0"* ]] || false
}

@test "cleanup_android_sdk removes x86 emulator images on Apple Silicon via safe_rm" {
    [ "$(uname -m)" = "arm64" ] || skip "x86 image removal only runs on arm64"
    make_file "$HOME/Library/Android/sdk/system-images/android-34/default/x86/img" 16
    make_file "$HOME/Library/Android/sdk/system-images/android-34/default/arm64-v8a/img" 16
    DRY_RUN=false
    RECLAIMED_KB=0
    cleanup_android_sdk > /dev/null
    [ ! -e "$HOME/Library/Android/sdk/system-images/android-34/default/x86" ]
    [ -d "$HOME/Library/Android/sdk/system-images/android-34/default/arm64-v8a" ]
    [ "$RECLAIMED_KB" -ge 16 ]
}

@test "shellcheck reports no errors and no new warnings" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    shellcheck -S error "$SCRIPT"
    # Baseline before this branch: 8 warnings (SC2155, SC2034, SC2206). Lower it, never raise it.
    [ "$(shellcheck -S warning -f gcc "$SCRIPT" | wc -l)" -le 8 ]
}
