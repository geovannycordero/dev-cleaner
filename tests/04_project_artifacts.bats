#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154  # globals are set/read by the sourced functions

load test_helper

setup_projects() {
    R="$HOME/repos"
    make_file "$R/web/package.json" 1
    make_file "$R/web/src/index.js" 1
    make_file "$R/web/node_modules/lodash/package.json" 1
    make_file "$R/web/node_modules/lodash/node_modules/x/index.js" 16
    make_file "$R/web/bin/run.sh" 1                         # Node scripts dir, no .NET project
    make_file "$R/api/Api.sln" 1
    make_file "$R/api/.vs/Api/v17/.suo" 16
    make_file "$R/api/src/Api/Api.csproj" 1
    make_file "$R/api/src/Api/Program.cs" 1
    make_file "$R/api/src/Api/bin/Debug/Api.dll" 16
    make_file "$R/api/src/Api/obj/project.assets.json" 16
    make_file "$R/api/src/Lib/Lib.fsproj" 1
    make_file "$R/api/src/Lib/obj/x" 4
    make_file "$R/tools/node_modules/orphan/index.js" 4     # no package.json next to it
    make_file "$R/.nvm/versions/node/v20/lib/node_modules/npm/package.json" 1
    make_file "$R/.nvm/versions/node/v20/lib/package.json" 1
    make_file "$R/.vscode/extensions/ext/package.json" 1
    make_file "$R/.vscode/extensions/ext/node_modules/dep/index.js" 4
    make_file "$R/Library/Caches/thing/package.json" 1
    make_file "$R/Library/Caches/thing/node_modules/dep/index.js" 4
    make_file "$R/Some.app/Contents/Resources/package.json" 1
    make_file "$R/Some.app/Contents/Resources/node_modules/dep/index.js" 4
    resolve_project_roots "$R"
    R="${PROJECT_ROOTS[0]}"
}

@test "find_node_modules returns top-level node_modules next to a package.json" {
    setup_projects
    run find_node_modules "$R"
    [ "$status" -eq 0 ]
    [ "$output" = "$R/web/node_modules" ]
}

@test "find_dotnet_artifacts returns bin/obj next to project files and .vs next to solutions" {
    setup_projects
    run find_dotnet_artifacts "$R"
    [ "$status" -eq 0 ]
    expected="$(printf '%s\n' "$R/api/.vs" "$R/api/src/Api/bin" "$R/api/src/Api/obj" "$R/api/src/Lib/obj")"
    [ "$(sort <<< "$output")" = "$expected" ]
}

@test "a scan root that is itself hidden is still scanned" {
    make_file "$HOME/.work/app/package.json" 1
    make_file "$HOME/.work/app/node_modules/x/index.js" 1
    run find_node_modules "$HOME/.work"
    [ "$output" = "$HOME/.work/app/node_modules" ]
}

@test "paths with spaces are found intact" {
    make_file "$HOME/my repos/app one/package.json" 1
    make_file "$HOME/my repos/app one/node_modules/x/index.js" 1
    run find_node_modules "$HOME/my repos"
    [ "$output" = "$HOME/my repos/app one/node_modules" ]
}

@test "cleanup_node_modules deletes only discovered dirs and credits space" {
    setup_projects
    DRY_RUN=false
    RECLAIMED_KB=0
    run cleanup_node_modules
    [ "$status" -eq 0 ]
    [ ! -e "$R/web/node_modules" ]
    [ -f "$R/web/package.json" ]
    [ -f "$R/web/src/index.js" ]
    [ -d "$R/tools/node_modules" ]
    [ -d "$R/.vscode/extensions/ext/node_modules" ]
    [ -d "$R/.nvm/versions/node/v20/lib/node_modules" ]
    [[ "$output" == *"1 removed"* ]] || false
}

@test "cleanup_node_modules credits the reclaimed total" {
    setup_projects
    DRY_RUN=false
    RECLAIMED_KB=0
    cleanup_node_modules > /dev/null
    [ "$RECLAIMED_KB" -ge 16 ]
}

@test "cleanup_dotnet_artifacts keeps sources and non-.NET bin dirs" {
    setup_projects
    DRY_RUN=false
    run cleanup_dotnet_artifacts
    [ "$status" -eq 0 ]
    [ ! -e "$R/api/src/Api/bin" ]
    [ ! -e "$R/api/src/Api/obj" ]
    [ ! -e "$R/api/src/Lib/obj" ]
    [ ! -e "$R/api/.vs" ]
    [ -f "$R/api/src/Api/Program.cs" ]
    [ -f "$R/api/src/Api/Api.csproj" ]
    [ -f "$R/web/bin/run.sh" ]
    [[ "$output" == *"4 removed"* ]] || false
}

@test "dry-run keeps every project artifact" {
    setup_projects
    DRY_RUN=true
    run cleanup_node_modules
    [[ "$output" == *"Would delete directory: $R/web/node_modules"* ]] || false
    [[ "$output" == *"1 would be removed"* ]] || false
    run cleanup_dotnet_artifacts
    [ -d "$R/web/node_modules" ]
    [ -d "$R/api/src/Api/bin" ]
    [ -d "$R/api/.vs" ]
}

@test "failed deletions are counted and the run continues" {
    setup_projects
    make_file "$R/second/package.json" 1
    make_file "$R/second/node_modules/x/index.js" 1
    chmod 555 "$R/web/node_modules/lodash"
    DRY_RUN=false
    run cleanup_node_modules
    chmod -R 755 "$R/web/node_modules"
    [ ! -e "$R/second/node_modules" ]
    [[ "$output" == *"1 removed, 1 failed"* ]] || false
}

@test "no project roots means nothing is scanned" {
    PROJECT_ROOTS=()
    run cleanup_node_modules
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping"* ]] || false
}

@test "estimate_all measures node_modules and .NET output" {
    setup_projects
    # || true: estimate_all relies on non-zero intermediate statuses (no set -e in the script)
    estimate_all > /dev/null || true
    [[ "$EST_node_modules_LABEL" == *Ki* || "$EST_node_modules_LABEL" == *Mi* ]] || false
    [[ "$EST_dotnet_LABEL" == *Ki* || "$EST_dotnet_LABEL" == *Mi* ]] || false
    [ "$EST_node_modules_LABEL" != "0Ki" ]
    [ "$EST_dotnet_LABEL" != "0Ki" ]
}
