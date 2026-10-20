#!/usr/bin/env bats

load test_helper

@test "sourcing the script defines functions without running the menu" {
    run bash -c "source '$SCRIPT' < /dev/null; type -t safe_rm"
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "executing the script still parses arguments" {
    run bash "$SCRIPT" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dev Cleaner v${SCRIPT_VERSION}"* ]] || false
}

@test "section headers render without a terminal" {
    run env -u TERM -u COLUMNS bash -c "source '$SCRIPT' < /dev/null; print_section_header Test"
    [ "$status" -eq 0 ]
    [[ "$output" != *tput* ]] || false
    [[ "$output" == *"➤ Test"* ]] || false
}
