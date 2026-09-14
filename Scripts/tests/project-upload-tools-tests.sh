#!/bin/zsh

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/../.." && pwd -P)"
wrapper="$project_root/Scripts/travel-cat-swift.sh"
audit="$project_root/Scripts/audit-project-upload.sh"

fail() {
    print -u2 -r -- "project-upload-tools-tests: $*"
    exit 1
}

[[ -x "$wrapper" ]] || fail "expected executable wrapper at $wrapper"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/travel-cat-project-upload-tools.XXXXXX")"
temporary_root="$(cd -- "$temporary_root" && pwd -P)"
trap 'rm -rf -- "$temporary_root"' EXIT

fixture_root="$temporary_root/fixture-project"
fake_bin_root="$temporary_root/fake-bin"
scratch_root="$temporary_root/external-scratch"
argument_log="$temporary_root/swift-arguments.log"
mkdir -p "$fixture_root/Scripts" "$fake_bin_root" "$scratch_root"
cp "$wrapper" "$fixture_root/Scripts/travel-cat-swift.sh"
chmod +x "$fixture_root/Scripts/travel-cat-swift.sh"

fake_swift="$fake_bin_root/swift"
cat > "$fake_swift" <<'FAKE_SWIFT'
#!/bin/zsh
set -euo pipefail
printf '%s\n' "$@" > "$TRAVEL_CAT_FAKE_SWIFT_LOG"
FAKE_SWIFT
chmod +x "$fake_swift"

expect_fake_rejection() {
    local label="$1"
    local expected_status="$2"
    shift 2
    rm -f "$argument_log"
    set +e
    TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
    TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
    TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
        "$fixture_root/Scripts/travel-cat-swift.sh" "$@" >"$temporary_root/$label.stdout" 2>"$temporary_root/$label.stderr"
    local actual_status=$?
    set -e
    (( actual_status == expected_status )) || fail "$label returned $actual_status instead of $expected_status"
    [[ ! -e "$argument_log" ]] || fail "$label invoked Swift"
}

rm -f "$argument_log"
set +e
scratch_path_output="$(
    TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
    TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
    TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
        "$fixture_root/Scripts/travel-cat-swift.sh" scratch-path
)"
scratch_path_status=$?
set -e

(( scratch_path_status == 0 )) || fail "scratch-path returned $scratch_path_status instead of 0"
[[ ! -e "$argument_log" ]] || fail "scratch-path invoked Swift"
[[ "$scratch_path_output" == "$scratch_root"/* ]] || fail "scratch-path output is outside the configured root"
[[ "$scratch_path_output" == "${scratch_path_output:A}" ]] || fail "scratch-path output is not physical and absolute"
[[ -d "$scratch_path_output" ]] || fail "scratch-path output was not created"
[[ "$(stat -f '%Lp' "$scratch_path_output")" == "700" ]] || fail "scratch-path output was not private"

second_fixture_root="$temporary_root/fixture-project-two"
mkdir -p "$second_fixture_root/Scripts"
cp "$wrapper" "$second_fixture_root/Scripts/travel-cat-swift.sh"
chmod +x "$second_fixture_root/Scripts/travel-cat-swift.sh"
second_scratch_path="$(
    TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
    TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
    TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
        "$second_fixture_root/Scripts/travel-cat-swift.sh" scratch-path
)" || fail "second worktree scratch-path failed"
[[ "$second_scratch_path" != "$scratch_path_output" ]] || fail "separate worktrees shared one scratch path"
[[ ! -e "$argument_log" ]] || fail "second scratch-path invoked Swift"

test_upload_audit() {
    [[ -x "$audit" ]] || fail "expected executable upload audit at $audit"

    local audit_test_root
    audit_test_root="$(mktemp -d "$temporary_root/audit-fixture.XXXXXX")"
    local audit_fixture="$audit_test_root/project"
    mkdir -p "$audit_fixture/Scripts" "$audit_fixture/Sources"
    cp "$audit" "$audit_fixture/Scripts/audit-project-upload.sh"
    cp "$project_root/.gitignore" "$audit_fixture/.gitignore"
    chmod +x "$audit_fixture/Scripts/audit-project-upload.sh"
    print -r -- "fixture" > "$audit_fixture/Sources/main.swift"
    print -r -- "space" > "$audit_fixture/Sources/space name.swift"
    local newline_tracked_path="$audit_fixture/Sources/"$'line\nname.swift'
    print -r -- "newline" > "$newline_tracked_path"
    print -r -- "tracked regular" > "$audit_fixture/Sources/typechange"
    git -C "$audit_fixture" init -q
    git -C "$audit_fixture" add .
    git -C "$audit_fixture" -c user.name='Travel Cat Tests' -c user.email='travel-cat-tests@example.invalid' \
        commit -qm 'initial fixture'

    local audit_status audit_stdout audit_stderr
    run_audit() {
        local label="$1"
        local threshold="${2-}"
        local stdout_path="$audit_test_root/$label.stdout"
        local stderr_path="$audit_test_root/$label.stderr"
        set +e
        if (( $# == 1 )); then
            "$audit_fixture/Scripts/audit-project-upload.sh" >"$stdout_path" 2>"$stderr_path"
        else
            TRAVEL_CAT_UPLOAD_MAX_BYTES="$threshold" \
                "$audit_fixture/Scripts/audit-project-upload.sh" >"$stdout_path" 2>"$stderr_path"
        fi
        audit_status=$?
        set -e
        audit_stdout="$(<"$stdout_path")"
        audit_stderr="$(<"$stderr_path")"
    }

    run_audit clean
    (( audit_status == 0 )) || fail "clean upload audit returned $audit_status: $audit_stderr"
    [[ "$audit_stdout" == *"upload-audit: physical_bytes="* ]] || fail "clean audit omitted physical bytes"
    [[ "$audit_stdout" == *"upload-audit: tracked_bytes="* ]] || fail "clean audit omitted tracked bytes"
    [[ "$audit_stdout" == *"upload-audit: staged_bytes=0"* ]] || fail "clean audit omitted staged bytes"
    [[ "$audit_stdout" == *"upload-audit: status=ok"* ]] || fail "clean audit did not report status=ok"

    mkdir -p "$audit_fixture/.build/cache"
    run_audit local-build
    (( audit_status == 65 )) || fail "local .build audit returned $audit_status instead of 65"
    [[ "$audit_stdout" == *"upload-audit: local bulk path exists: .build"* ]] || fail "local .build was not reported"
    rm -rf -- "$audit_fixture/.build"
    run_audit after-local-build
    (( audit_status == 0 )) || fail "audit did not recover after removing local .build"

    mkdir -p "$audit_fixture/Sources/generated/.build/cache"
    run_audit nested-local-build
    (( audit_status == 65 )) || fail "nested .build audit returned $audit_status instead of 65"
    [[ "$audit_stdout" == *"upload-audit: local bulk path exists: Sources/generated/.build"* ]] || fail "nested .build was not reported"
    rm -rf -- "$audit_fixture/Sources/generated"
    run_audit after-nested-local-build
    (( audit_status == 0 )) || fail "audit did not recover after removing nested .build"

    mkdir -p "$audit_fixture/Sources/generated/.BuIlD/cache"
    run_audit mixed-case-local-build
    (( audit_status == 65 )) || fail "mixed-case local .build returned $audit_status instead of 65"
    [[ "$audit_stdout" == *"upload-audit: local bulk path exists: Sources/generated/.BuIlD"* ]] || fail "mixed-case local .build was not reported"
    rm -rf -- "$audit_fixture/Sources/generated"

    dd if=/dev/zero of="$audit_fixture/new-large.bin" bs=2048 count=1 2>/dev/null
    git -C "$audit_fixture" add new-large.bin
    run_audit oversized 1024
    (( audit_status == 65 )) || fail "oversized staged file returned $audit_status instead of 65"
    [[ "$audit_stdout" == *$'upload-audit: staged file exceeds limit: path=new-large.bin bytes=2048 limit=1024'* ]] || \
        fail "oversized staged file was not reported exactly: $audit_stdout"
    git -C "$audit_fixture" reset -q HEAD -- new-large.bin
    rm -f -- "$audit_fixture/new-large.bin"
    run_audit after-oversized 1024
    (( audit_status == 0 )) || fail "audit did not recover after removing oversized staged file"

    dd if=/dev/zero of="$audit_fixture/Sources/first-600.swift" bs=600 count=1 2>/dev/null
    dd if=/dev/zero of="$audit_fixture/Sources/second-600.swift" bs=600 count=1 2>/dev/null
    git -C "$audit_fixture" add Sources/first-600.swift Sources/second-600.swift
    run_audit per-file-threshold 1024
    (( audit_status == 0 )) || fail "two individually valid staged files returned $audit_status: $audit_stdout"
    [[ "$audit_stdout" == *"upload-audit: staged_bytes=1200"* ]] || fail "two staged files did not report their total bytes"
    git -C "$audit_fixture" reset -q HEAD -- Sources/first-600.swift Sources/second-600.swift
    rm -f -- "$audit_fixture/Sources/first-600.swift" "$audit_fixture/Sources/second-600.swift"

    local magic_large_path=':(literal)large-source'
    dd if=/dev/zero of="$audit_fixture/$magic_large_path" bs=2048 count=1 2>/dev/null
    git -C "$audit_fixture" --literal-pathspecs add -- "$magic_large_path"
    run_audit magic-oversized 1024
    (( audit_status == 65 )) || fail "magic-named oversized file returned $audit_status instead of 65"
    local magic_large_display="${(q)magic_large_path}"
    [[ "$audit_stdout" == *"path=$magic_large_display bytes=2048 limit=1024"* ]] || fail "magic-named oversized file path was not safely reported"
    git -C "$audit_fixture" --literal-pathspecs reset -q HEAD -- "$magic_large_path"
    rm -f -- "$audit_fixture/$magic_large_path"

    mkdir -p "$audit_fixture/dist"
    print -r -- "package" > "$audit_fixture/dist/test.pkg"
    git -C "$audit_fixture" add -f dist/test.pkg
    run_audit prohibited-dist
    (( audit_status == 65 )) || fail "prohibited dist package returned $audit_status instead of 65"
    [[ "$audit_stdout" == *"upload-audit: prohibited staged path: dist/test.pkg"* ]] || fail "prohibited dist package was not reported"
    [[ "$audit_stdout" == *"upload-audit: staged_bytes=8"* ]] || fail "prohibited regular file was omitted from staged bytes"
    git -C "$audit_fixture" reset -q HEAD -- dist/test.pkg
    rm -rf -- "$audit_fixture/dist"

    mkdir -p "$audit_fixture/.swiftpm" "$audit_fixture/DerivedData"
    dd if=/dev/zero of="$audit_fixture/.swiftpm/cache.bin" bs=10 count=1 2>/dev/null
    dd if=/dev/zero of="$audit_fixture/DerivedData/cache.bin" bs=20 count=1 2>/dev/null
    dd if=/dev/zero of="$audit_fixture/Debug.dSYM.zip" bs=30 count=1 2>/dev/null
    git -C "$audit_fixture" add -f .swiftpm/cache.bin DerivedData/cache.bin Debug.dSYM.zip
    run_audit generated-policy
    (( audit_status == 65 )) || fail "generated staged paths returned $audit_status instead of 65"
    for generated_path in .swiftpm/cache.bin DerivedData/cache.bin Debug.dSYM.zip; do
        [[ "$audit_stdout" == *"upload-audit: prohibited staged path: $generated_path"* ]] || fail "generated path was not reported: $generated_path"
    done
    [[ "$audit_stdout" == *"upload-audit: staged_bytes=60"* ]] || fail "generated regular blobs were omitted from staged bytes"
    git -C "$audit_fixture" reset -q HEAD -- .swiftpm/cache.bin DerivedData/cache.bin Debug.dSYM.zip
    rm -rf -- "$audit_fixture/.swiftpm" "$audit_fixture/DerivedData"
    rm -f -- "$audit_fixture/Debug.dSYM.zip"

    mkdir -p "$audit_fixture/DIST" "$audit_fixture/DERIVEDDATA"
    dd if=/dev/zero of="$audit_fixture/DIST/package.DMG" bs=10 count=1 2>/dev/null
    dd if=/dev/zero of="$audit_fixture/DERIVEDDATA/cache.bin" bs=20 count=1 2>/dev/null
    dd if=/dev/zero of="$audit_fixture/release.PKG" bs=30 count=1 2>/dev/null
    dd if=/dev/zero of="$audit_fixture/debug.LOG" bs=40 count=1 2>/dev/null
    local -a mixed_case_generated_paths
    mixed_case_generated_paths=(DIST/package.DMG DERIVEDDATA/cache.bin release.PKG debug.LOG)
    git -C "$audit_fixture" add -f -- "${mixed_case_generated_paths[@]}"
    run_audit mixed-case-generated-policy
    (( audit_status == 65 )) || fail "mixed-case generated staged paths returned $audit_status instead of 65"
    for generated_path in "${mixed_case_generated_paths[@]}"; do
        [[ "$audit_stdout" == *"upload-audit: prohibited staged path: $generated_path"* ]] || fail "mixed-case generated path was not reported: $generated_path"
    done
    [[ "$audit_stdout" == *"upload-audit: staged_bytes=100"* ]] || fail "mixed-case generated blobs were omitted from staged bytes"
    git -C "$audit_fixture" reset -q HEAD -- "${mixed_case_generated_paths[@]}"
    rm -rf -- "$audit_fixture/DIST" "$audit_fixture/DERIVEDDATA"
    rm -f -- "$audit_fixture/release.PKG" "$audit_fixture/debug.LOG"

    local small_source_path="Sources/"$'new\nsmall.swift'
    print -r -- "small source" > "$audit_fixture/$small_source_path"
    git -C "$audit_fixture" add -- "$small_source_path"
    run_audit small-source
    (( audit_status == 0 )) || fail "small staged source returned $audit_status: $audit_stdout $audit_stderr"
    git -C "$audit_fixture" reset -q HEAD -- "$small_source_path"
    rm -f -- "$audit_fixture/$small_source_path"

    mkdir -p "$audit_fixture/Assets" "$audit_fixture/Fixtures" "$audit_fixture/Tests/Fixtures" "$audit_fixture/Sources/TravelUI/Resources"
    print -r -- "asset log" > "$audit_fixture/Assets/runtime.log"
    print -r -- "compiler output" > "$audit_fixture/Fixtures/compiler.out"
    print -r -- "uppercase compiler output" > "$audit_fixture/Fixtures/sample.OUT"
    print -r -- "test fixture log" > "$audit_fixture/Tests/Fixtures/parser.log"
    print -r -- "resource error" > "$audit_fixture/Sources/TravelUI/Resources/sample.err"
    local -a formal_sample_paths
    formal_sample_paths=(Assets/runtime.log Fixtures/compiler.out Fixtures/sample.OUT Tests/Fixtures/parser.log Sources/TravelUI/Resources/sample.err)
    for sample_path in "${formal_sample_paths[@]}"; do
        if git -C "$audit_fixture" check-ignore -q -- "$sample_path"; then
            fail "formal sample tree file is unexpectedly ignored: $sample_path"
        fi
    done
    git -C "$audit_fixture" add -- "${formal_sample_paths[@]}"
    run_audit formal-sample-logs
    (( audit_status == 0 )) || fail "formal sample logs returned $audit_status: $audit_stdout $audit_stderr"
    git -C "$audit_fixture" reset -q HEAD -- "${formal_sample_paths[@]}"
    rm -rf -- "$audit_fixture/Assets" "$audit_fixture/Fixtures" "$audit_fixture/Tests" "$audit_fixture/Sources/TravelUI"

    mkdir -p "$audit_fixture/ASSETS" "$audit_fixture/TESTS/FIXTURES" "$audit_fixture/SOURCES/TRAVELUI/RESOURCES"
    print -r -- "uppercase fake asset" > "$audit_fixture/ASSETS/review.LOG"
    print -r -- "uppercase fake fixture" > "$audit_fixture/TESTS/FIXTURES/review.OUT"
    print -r -- "uppercase fake resource" > "$audit_fixture/SOURCES/TRAVELUI/RESOURCES/review.ERR"
    local -a uppercase_fake_formal_paths
    uppercase_fake_formal_paths=(ASSETS/review.LOG TESTS/FIXTURES/review.OUT SOURCES/TRAVELUI/RESOURCES/review.ERR)
    for sample_path in "${uppercase_fake_formal_paths[@]}"; do
        sample_object="$(git -C "$audit_fixture" hash-object -w -- "$audit_fixture/$sample_path")"
        git -C "$audit_fixture" update-index --add --cacheinfo 100644 "$sample_object" "$sample_path"
    done
    run_audit uppercase-fake-formal-trees
    (( audit_status == 65 )) || fail "uppercase fake formal trees returned $audit_status instead of 65"
    for sample_name in review.LOG review.OUT review.ERR; do
        [[ "$audit_stdout" == *"upload-audit: prohibited staged path: "*"$sample_name"* ]] || fail "uppercase fake formal tree was not reported: $sample_name"
    done
    git -C "$audit_fixture" reset -q HEAD -- .
    rm -rf -- "$audit_fixture/ASSETS" "$audit_fixture/TESTS"
    rm -f -- "$audit_fixture/SOURCES/TRAVELUI/RESOURCES/review.ERR"
    rmdir "$audit_fixture/SOURCES/TRAVELUI/RESOURCES" "$audit_fixture/SOURCES/TRAVELUI" 2>/dev/null || true
    rmdir "$audit_fixture/SOURCES" 2>/dev/null || true

    mkdir -p "$audit_fixture/Scratch/ASSETS" "$audit_fixture/Vendor/Fixtures" "$audit_fixture/Sources/Other/Resources"
    print -r -- "scratch log" > "$audit_fixture/Scratch/ASSETS/debug.LOG"
    print -r -- "vendor output" > "$audit_fixture/Vendor/Fixtures/tool.out"
    print -r -- "other resource error" > "$audit_fixture/Sources/Other/Resources/debug.err"
    local -a nonformal_sample_paths
    nonformal_sample_paths=(Scratch/ASSETS/debug.LOG Vendor/Fixtures/tool.out Sources/Other/Resources/debug.err)
    for sample_path in "${nonformal_sample_paths[@]}"; do
        if ! git -C "$audit_fixture" check-ignore -q -- "$sample_path"; then
            fail "non-formal sample path is unexpectedly unignored: $sample_path"
        fi
    done
    git -C "$audit_fixture" add -f -- "${nonformal_sample_paths[@]}"
    run_audit nonformal-sample-logs
    (( audit_status == 65 )) || fail "non-formal sample logs returned $audit_status instead of 65"
    for sample_path in "${nonformal_sample_paths[@]}"; do
        [[ "$audit_stdout" == *"upload-audit: prohibited staged path: $sample_path"* ]] || fail "non-formal sample log was not reported: $sample_path"
    done
    git -C "$audit_fixture" reset -q HEAD -- "${nonformal_sample_paths[@]}"
    rm -rf -- "$audit_fixture/Scratch" "$audit_fixture/Vendor" "$audit_fixture/Sources/Other"

    print -r -- "temporary output" > "$audit_fixture/Sources/compiler.out"
    git -C "$audit_fixture" add -f Sources/compiler.out
    run_audit temporary-output
    (( audit_status == 65 )) || fail "temporary output outside formal trees returned $audit_status instead of 65"
    [[ "$audit_stdout" == *"upload-audit: prohibited staged path: Sources/compiler.out"* ]] || fail "temporary output outside formal trees was not reported"
    git -C "$audit_fixture" reset -q HEAD -- Sources/compiler.out
    rm -f -- "$audit_fixture/Sources/compiler.out"

    run_audit nondigit invalid
    (( audit_status == 64 )) || fail "non-numeric threshold returned $audit_status instead of 64"
    run_audit negative -1
    (( audit_status == 64 )) || fail "negative threshold returned $audit_status instead of 64"
    run_audit empty ""
    (( audit_status == 64 )) || fail "empty threshold returned $audit_status instead of 64"

    ln -s missing-target "$audit_fixture/.worktrees"
    run_audit broken-bulk-symlink
    (( audit_status == 65 )) || fail "broken bulk symlink returned $audit_status instead of 65"
    [[ "$audit_stdout" == *"upload-audit: local bulk path exists: .worktrees"* ]] || fail "broken bulk symlink was not reported"
    rm -f -- "$audit_fixture/.worktrees"

    local staged_symlink_path="Sources/"$'staged\nlink'
    ln -s missing-target "$audit_fixture/$staged_symlink_path"
    git -C "$audit_fixture" add -- "$staged_symlink_path"
    run_audit staged-symlink
    (( audit_status == 65 )) || fail "staged symlink returned $audit_status instead of 65"
    local staged_symlink_display="${(q)staged_symlink_path}"
    [[ "$audit_stdout" == *"upload-audit: prohibited staged symlink: $staged_symlink_display"* ]] || fail "staged symlink was not safely reported"
    [[ "$audit_stdout" != *"$staged_symlink_path"* ]] || fail "staged symlink diagnostic contained an ambiguous raw newline"
    git -C "$audit_fixture" reset -q HEAD -- "$staged_symlink_path"
    rm -f -- "$audit_fixture/$staged_symlink_path"

    rm -f -- "$audit_fixture/Sources/typechange"
    ln -s missing-target "$audit_fixture/Sources/typechange"
    git -C "$audit_fixture" add Sources/typechange
    run_audit staged-typechange-symlink
    (( audit_status == 65 )) || fail "regular-to-symlink typechange returned $audit_status instead of 65"
    [[ "$audit_stdout" == *"upload-audit: prohibited staged symlink: Sources/typechange"* ]] || fail "typechange symlink was not reported"
    git -C "$audit_fixture" reset -q HEAD -- Sources/typechange
    rm -f -- "$audit_fixture/Sources/typechange"
    git -C "$audit_fixture" checkout -q -- Sources/typechange

    local magic_symlink_path=':(literal)staged-link'
    ln -s missing-target "$audit_fixture/$magic_symlink_path"
    git -C "$audit_fixture" --literal-pathspecs add -- "$magic_symlink_path"
    run_audit magic-staged-symlink
    (( audit_status == 65 )) || fail "magic-named staged symlink returned $audit_status instead of 65"
    local magic_symlink_display="${(q)magic_symlink_path}"
    [[ "$audit_stdout" == *"upload-audit: prohibited staged symlink: $magic_symlink_display"* ]] || fail "magic-named staged symlink was not safely reported"
    git -C "$audit_fixture" --literal-pathspecs reset -q HEAD -- "$magic_symlink_path"
    rm -f -- "$audit_fixture/$magic_symlink_path"

    run_audit final-clean
    (( audit_status == 0 )) || fail "final clean upload audit returned $audit_status"

    print -rn -- "broken-index" > "$audit_fixture/.git/index"
    run_audit corrupt-index
    (( audit_status == 70 )) || fail "corrupt index returned $audit_status instead of 70"
    [[ "$audit_stdout" != *"upload-audit: status=ok"* ]] || fail "corrupt index incorrectly reported status=ok"
}

TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" test --filter CLIContractTests --parallel

arguments=("${(@f)$(<"$argument_log")}")
(( ${#arguments} == 6 )) || fail "expected 6 Swift arguments, got ${#arguments}"
[[ "${arguments[1]}" == "test" ]] || fail "Swift subcommand was not preserved"
[[ "${arguments[2]}" == "--scratch-path" ]] || fail "wrapper did not inject --scratch-path"
scratch_path="${arguments[3]}"
[[ "${arguments[4]}" == "--filter" ]] || fail "first caller argument was not preserved"
[[ "${arguments[5]}" == "CLIContractTests" ]] || fail "second caller argument was not preserved"
[[ "${arguments[6]}" == "--parallel" ]] || fail "third caller argument was not preserved"
[[ "$scratch_path" == "$scratch_root"/* ]] || fail "scratch path is outside the configured scratch root"
[[ "$scratch_path" != "$fixture_root"(|/*) ]] || fail "scratch path is inside the fixture project"
[[ "${scratch_path:t}" =~ '^[0-9a-f]{16}$' ]] || fail "scratch cache id is not a 16-character SHA-256 prefix"
[[ -d "$scratch_path" && -w "$scratch_path" ]] || fail "scratch path was not created writable"
[[ "$(stat -f '%Lp' "$scratch_path")" == "700" ]] || fail "scratch path was not created with private permissions"

rm -f "$argument_log"
mkdir -p "$fixture_root/Sources/ArgEcho"
cat > "$fixture_root/Package.swift" <<'PACKAGE_SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArgEchoFixture",
    products: [
        .executable(name: "ArgEcho", targets: ["ArgEcho"]),
    ],
    targets: [
        .executableTarget(name: "ArgEcho"),
    ]
)
PACKAGE_SWIFT
cat > "$fixture_root/Sources/ArgEcho/main.swift" <<'ARG_ECHO_SWIFT'
import Foundation

let outputPath = ProcessInfo.processInfo.environment["ARG_ECHO_OUTPUT"]!
let arguments = CommandLine.arguments.dropFirst().joined(separator: "\n")
try arguments.write(toFile: outputPath, atomically: true, encoding: .utf8)
ARG_ECHO_SWIFT

real_swift="$(command -v swift)"
e2e_scratch_root="$temporary_root/e2e-scratch"
e2e_module_cache="$temporary_root/e2e-module-cache"
e2e_argument_log="$temporary_root/arg-echo-arguments.log"
mkdir -p "$e2e_module_cache"
set +e
ARG_ECHO_OUTPUT="$e2e_argument_log" \
SWIFTPM_MODULECACHE_OVERRIDE="$e2e_module_cache" \
CLANG_MODULE_CACHE_PATH="$e2e_module_cache" \
TRAVEL_CAT_SWIFT_BIN="$real_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$e2e_scratch_root" \
    "$fixture_root/Scripts/travel-cat-swift.sh" run ArgEcho --scratch-path payload --exec -c >"$temporary_root/e2e-run.stdout" 2>"$temporary_root/e2e-run.stderr"
e2e_status=$?
set -e

(( e2e_status == 0 )) || fail "real ArgEcho run returned $e2e_status instead of 0: $(<"$temporary_root/e2e-run.stderr")"
e2e_arguments=("${(@f)$(<"$e2e_argument_log")}")
(( ${#e2e_arguments} == 4 )) || fail "real ArgEcho received ${#e2e_arguments} arguments instead of 4"
[[ "${e2e_arguments[1]}" == "--scratch-path" ]] || fail "real ArgEcho did not preserve the program flag"
[[ "${e2e_arguments[2]}" == "payload" ]] || fail "real ArgEcho did not preserve the program value"
[[ "${e2e_arguments[3]}" == "--exec" ]] || fail "real ArgEcho did not preserve the --exec program argument"
[[ "${e2e_arguments[4]}" == "-c" ]] || fail "real ArgEcho did not preserve the -c program argument"
e2e_cache_id="$(print -rn -- "$fixture_root" | shasum -a 256 | cut -c 1-16)"
[[ -d "$e2e_scratch_root/$e2e_cache_id" ]] || fail "real ArgEcho did not use the external scratch path"
[[ "$(stat -f '%Lp' "$e2e_scratch_root")" == "700" ]] || fail "new external scratch root was not created with mode 700"
[[ ! -e "$fixture_root/.build" ]] || fail "real ArgEcho created a fixture .build"

set +e
TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" run ArgEcho --scratch-path payload --exec -c >"$temporary_root/separated-run.stdout" 2>"$temporary_root/separated-run.stderr"
separated_run_status=$?
set -e

(( separated_run_status == 0 )) || fail "separated run arguments returned $separated_run_status instead of 0"
separated_arguments=("${(@f)$(<"$argument_log")}")
(( ${#separated_arguments} == 9 )) || fail "expected 9 separated run arguments, got ${#separated_arguments}"
[[ "${separated_arguments[1]}" == "run" ]] || fail "separated run subcommand was not preserved"
[[ "${separated_arguments[2]}" == "--scratch-path" ]] || fail "separated run lost the injected scratch flag"
[[ "${separated_arguments[3]}" == "$scratch_path" ]] || fail "separated run changed the injected scratch path"
[[ "${separated_arguments[4]}" == "--" ]] || fail "separated run did not terminate SwiftPM option parsing"
[[ "${separated_arguments[5]}" == "ArgEcho" ]] || fail "separated run changed the executable argument"
[[ "${separated_arguments[6]}" == "--scratch-path" ]] || fail "separated run changed the program flag"
[[ "${separated_arguments[7]}" == "payload" ]] || fail "separated run changed the program flag value"
[[ "${separated_arguments[8]}" == "--exec" ]] || fail "separated run changed the --exec program argument"
[[ "${separated_arguments[9]}" == "-c" ]] || fail "separated run changed the -c program argument"
rm -f "$argument_log"

TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" run ArgEcho --scratch-path=payload --exec -c
program_domain_arguments=("${(@f)$(<"$argument_log")}")
(( ${#program_domain_arguments} == 8 )) || fail "expected 8 program-domain arguments, got ${#program_domain_arguments}"
[[ "${program_domain_arguments[4]}" == "--" ]] || fail "program-domain Swift delimiter was not injected"
[[ "${program_domain_arguments[5]}" == "ArgEcho" ]] || fail "program-domain executable was not preserved"
[[ "${program_domain_arguments[6]}" == "--scratch-path=payload" ]] || fail "program-domain scratch-shaped argument was not preserved"
[[ "${program_domain_arguments[7]}" == "--exec" ]] || fail "program-domain --exec argument was not preserved"
[[ "${program_domain_arguments[8]}" == "-c" ]] || fail "program-domain -c argument was not preserved"
rm -f "$argument_log"

unsafe_scratch_root="$temporary_root/unsafe-root"
mkdir -p "$unsafe_scratch_root"
chmod 777 "$unsafe_scratch_root"
set +e
TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$unsafe_scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" scratch-path >"$temporary_root/unsafe-root.stdout" 2>"$temporary_root/unsafe-root.stderr"
unsafe_root_status=$?
set -e

(( unsafe_root_status == 73 )) || fail "mode-777 scratch root returned $unsafe_root_status instead of 73"
[[ ! -e "$argument_log" ]] || fail "mode-777 scratch root invoked Swift"

mode_scratch_root="$temporary_root/mode-scratch"
mode_cache_id="$(print -rn -- "$fixture_root" | shasum -a 256 | cut -c 1-16)"
mode_scratch_path="$mode_scratch_root/$mode_cache_id"
mkdir -p "$mode_scratch_path"
chmod 755 "$mode_scratch_path"
set +e
TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$mode_scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" build >"$temporary_root/mode-scratch.stdout" 2>"$temporary_root/mode-scratch.stderr"
mode_scratch_status=$?
set -e

(( mode_scratch_status == 0 )) || fail "existing mode-755 scratch path returned $mode_scratch_status instead of 0"
[[ "$(stat -f '%Lp' "$mode_scratch_root")" == "755" ]] || fail "existing mode-755 scratch root permissions were changed"
[[ "$(stat -f '%Lp' "$mode_scratch_path")" == "700" ]] || fail "existing mode-755 scratch path was not tightened to 700"
[[ -e "$argument_log" ]] || fail "existing mode-755 scratch path did not invoke Swift"
rm -f "$argument_log"

set +e
(
    cd "$temporary_root"
    TRAVEL_CAT_SWIFT_BIN="./fake-bin/swift" \
    TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
    TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
        "$fixture_root/Scripts/travel-cat-swift.sh" run travelcatctl --version
) >"$temporary_root/relative-swift.stdout" 2>"$temporary_root/relative-swift.stderr"
relative_swift_status=$?
set -e

(( relative_swift_status == 0 )) || fail "relative Swift executable returned $relative_swift_status instead of 0"
relative_arguments=("${(@f)$(<"$argument_log")}")
[[ "${relative_arguments[1]}" == "run" ]] || fail "relative Swift executable was not invoked"
rm -f "$argument_log"

set +e
TRAVEL_CAT_SWIFT_BIN="$temporary_root/missing-swift" \
TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" build >"$temporary_root/missing-swift.stdout" 2>"$temporary_root/missing-swift.stderr"
missing_swift_status=$?
set -e

(( missing_swift_status == 69 )) || fail "missing Swift executable returned $missing_swift_status instead of 69"
[[ ! -e "$argument_log" ]] || fail "missing Swift executable invoked Swift"

caller_scratch_path="$fixture_root/.build"
expect_fake_rejection "run-delimiter-bypass" 64 run -- --scratch-path "$caller_scratch_path" ArgEcho
[[ ! -e "$caller_scratch_path" ]] || fail "run delimiter bypass created a repository .build"
expect_fake_rejection "run-scratch-equals" 64 run "--scratch-path=$caller_scratch_path" --exec ArgEcho
expect_fake_rejection "run-scratch-spaced" 64 run --scratch-path "$caller_scratch_path" --exec ArgEcho
expect_fake_rejection "run-missing-executable" 64 run
expect_fake_rejection "run-empty-executable" 64 run ""
expect_fake_rejection "run-exec-prefix" 64 run --exec
expect_fake_rejection "run-option-prefix" 64 run -c debug ArgEcho
expect_fake_rejection "test-scratch-after-delimiter" 64 test -- --scratch-path "$caller_scratch_path"
expect_fake_rejection "build-scratch-equals" 64 build "--scratch-path=$caller_scratch_path"
[[ ! -e "$caller_scratch_path" ]] || fail "caller scratch overrides created a repository .build"

legacy_scratch_root="$temporary_root/legacy-bypass-scratch"
set +e
TRAVEL_CAT_SWIFT_BIN="$real_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$legacy_scratch_root" \
    "$fixture_root/Scripts/travel-cat-swift.sh" run -c --exec debug --scratch-path "$caller_scratch_path" ArgEcho >"$temporary_root/legacy-bypass.stdout" 2>"$temporary_root/legacy-bypass.stderr"
legacy_bypass_status=$?
set -e

(( legacy_bypass_status == 64 )) || fail "legacy real-Swift bypass returned $legacy_bypass_status instead of 64"
[[ ! -e "$legacy_scratch_root" ]] || fail "legacy real-Swift bypass created external build data"
[[ ! -e "$caller_scratch_path" ]] || fail "legacy real-Swift bypass created a repository .build"

symlink_scratch_root="$temporary_root/symlink-scratch"
expected_cache_id="$(print -rn -- "$fixture_root" | shasum -a 256 | cut -c 1-16)"
mkdir -p "$symlink_scratch_root" "$fixture_root/.build"
ln -s "$fixture_root/.build" "$symlink_scratch_root/$expected_cache_id"
set +e
TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$symlink_scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" scratch-path >"$temporary_root/symlink.stdout" 2>"$temporary_root/symlink.stderr"
symlink_status=$?
set -e

(( symlink_status != 0 )) || fail "symlink scratch path was accepted"
[[ ! -e "$argument_log" ]] || fail "symlink scratch path invoked Swift"
[[ -z "$(find "$fixture_root/.build" -mindepth 1 -print -quit)" ]] || fail "symlink scratch path wrote inside the fixture project"
rm "$symlink_scratch_root/$expected_cache_id"
rmdir "$fixture_root/.build"

internal_scratch_root="$fixture_root/.build"
set +e
TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$internal_scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" scratch-path >"$temporary_root/internal.stdout" 2>"$temporary_root/internal.stderr"
internal_status=$?
set -e

(( internal_status != 0 )) || fail "project-internal scratch root was accepted"
[[ ! -e "$internal_scratch_root" ]] || fail "wrapper created scratch data inside the fixture project"
[[ ! -e "$argument_log" ]] || fail "project-internal scratch root invoked Swift"

set +e
TRAVEL_CAT_SWIFT_BIN="$fake_swift" \
TRAVEL_CAT_SCRATCH_ROOT="$scratch_root" \
TRAVEL_CAT_FAKE_SWIFT_LOG="$argument_log" \
    "$fixture_root/Scripts/travel-cat-swift.sh" package >"$temporary_root/unsupported.stdout" 2>"$temporary_root/unsupported.stderr"
unsupported_status=$?
set -e

(( unsupported_status == 64 )) || fail "unsupported subcommand returned $unsupported_status instead of 64"
[[ ! -e "$argument_log" ]] || fail "unsupported subcommand invoked Swift"
[[ -s "$temporary_root/unsupported.stderr" ]] || fail "unsupported subcommand did not report an error"

test_upload_audit

print -r -- "project-upload-tools-tests: PASS"
