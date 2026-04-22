#!/usr/bin/env bash
# tests/run-tests.sh — minimal golden-file test runner for kconform Phase 0.
#
# Test layout:
#   tests/cases/<verb>/<scenario>/
#     cmd              One-line shell command to execute, relative to the test's
#                      working directory. $KCONFORM is substituted with the
#                      absolute path to cli/kconform.
#     cwd              Optional. Path (relative to the repo root) that the
#                      command is run from. Defaults to the repo root.
#     expected-exit    Expected integer exit code.
#     expected-stdout  Optional. Substring(s) that must appear in stdout
#                      (one per line; all must match).
#     expected-stderr  Optional. Substring(s) that must appear in stderr.
#
# Run all: ./tests/run-tests.sh
# Run one: ./tests/run-tests.sh lint/ghost-symbol-clean

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KCONFORM="$REPO_ROOT/cli/kconform"
CASES_DIR="$REPO_ROOT/tests/cases"

pass_count=0
fail_count=0
failed_cases=()

_check_substrings() {
    local label="$1"
    local expected_file="$2"
    local actual="$3"
    [ -f "$expected_file" ] || return 0
    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        if ! printf '%s' "$actual" | grep -qF -- "$pattern"; then
            printf '    %s missing expected substring: %s\n' "$label" "$pattern" >&2
            printf '    actual %s was:\n' "$label" >&2
            printf '%s\n' "$actual" | sed 's/^/      /' >&2
            return 1
        fi
    done <"$expected_file"
    return 0
}

run_case() {
    local case_dir="$1"
    local name="${case_dir#"$CASES_DIR"/}"

    local cmd_file="$case_dir/cmd"
    if [ ! -f "$cmd_file" ]; then
        echo "SKIP $name (no cmd file)"
        return 0
    fi

    local expected_exit=0
    if [ -f "$case_dir/expected-exit" ]; then
        expected_exit="$(tr -d '[:space:]' <"$case_dir/expected-exit")"
    fi

    local cwd="$REPO_ROOT"
    if [ -f "$case_dir/cwd" ]; then
        local cwd_rel
        cwd_rel="$(tr -d '[:space:]' <"$case_dir/cwd")"
        cwd="$REPO_ROOT/$cwd_rel"
    fi

    local cmd
    cmd="$(cat "$cmd_file")"
    # Make the kconform binary available via $KCONFORM in the test's cmd file.
    cmd="${cmd//\$KCONFORM/$KCONFORM}"

    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"

    local actual_exit=0
    ( cd "$cwd" && bash -c "$cmd" ) >"$stdout_file" 2>"$stderr_file" || actual_exit=$?

    local ok=1
    if [ "$actual_exit" != "$expected_exit" ]; then
        printf '  exit code mismatch: expected=%s actual=%s\n' "$expected_exit" "$actual_exit" >&2
        ok=0
    fi
    if ! _check_substrings "stdout" "$case_dir/expected-stdout" "$(cat "$stdout_file")"; then
        ok=0
    fi
    if ! _check_substrings "stderr" "$case_dir/expected-stderr" "$(cat "$stderr_file")"; then
        ok=0
    fi

    rm -f "$stdout_file" "$stderr_file"

    if [ $ok -eq 1 ]; then
        printf 'PASS  %s\n' "$name"
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL  %s\n' "$name" >&2
        fail_count=$((fail_count + 1))
        failed_cases+=("$name")
    fi
}

main() {
    if [ ! -x "$KCONFORM" ]; then
        echo "error: $KCONFORM is not executable" >&2
        exit 2
    fi

    local filter="${1:-}"
    local case_dir
    # List directories containing a `cmd` file, sorted.
    while IFS= read -r case_dir; do
        [ -z "$case_dir" ] && continue
        local name="${case_dir#"$CASES_DIR"/}"
        if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
            continue
        fi
        run_case "$case_dir"
    done < <(find "$CASES_DIR" -type f -name cmd -printf '%h\n' 2>/dev/null | sort)

    echo ""
    echo "---------------------------------"
    printf 'passed: %d   failed: %d\n' "$pass_count" "$fail_count"
    if [ $fail_count -gt 0 ]; then
        printf 'failed cases:\n'
        for c in "${failed_cases[@]}"; do
            printf '  %s\n' "$c"
        done
        exit 1
    fi
}

main "$@"
