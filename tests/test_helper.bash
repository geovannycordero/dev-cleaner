# Shared setup: every test gets a throwaway HOME and stubbed external tools,
# so nothing a test does can reach the real machine.
bats_require_minimum_version 1.5.0
SCRIPT="$BATS_TEST_DIRNAME/../dev-cleaner.sh"

setup() {
    # HOME must be set before sourcing: paths like CLAUDE_VERSIONS_DIR are
    # computed when the script loads.
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    export STUB_OUT_DIR="$BATS_TEST_TMPDIR/out"
    : > "$STUB_LOG"
    mkdir -p "$STUB_OUT_DIR"
    PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
    # shellcheck source=dev-cleaner.sh
    source "$SCRIPT" < /dev/null
}

# Make a file of roughly <kb> KB.
make_file() {
    mkdir -p "$(dirname "$1")"
    dd if=/dev/zero of="$1" bs=1024 count="${2:-64}" 2>/dev/null
}
