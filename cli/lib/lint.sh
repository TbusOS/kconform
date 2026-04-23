# cli/lib/lint.sh — lint rule runner and the `lint` verb.
#
# Sourced by cli/kconform. Expects KCONFORM_ROOT and KCONFORM_CLI_DIR in env,
# plus detect.sh already sourced.
#
# Rules live under cli/lib/lint-rules/<ID>-<name>.sh. Each rule is invoked as:
#     bash <rule.sh> <defconfig> <project_root> <platform>
# and prints zero or more findings to stdout, one JSON object per line:
#     {"rule":"L001","severity":"error","symbol":"CONFIG_X","message":"...","fix":"..."}

cmd_lint() {
    local defconfig=""
    local mode="text"
    local platform_override=""
    local deep="0"
    local keep_scratch="0"

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) mode="json"; shift ;;
            --deep) deep="1"; shift ;;
            --keep-scratch) keep_scratch="1"; shift ;;
            --platform=*) platform_override="${1#--platform=}"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform lint <defconfig> [--platform=<name>] [--json] [--deep] [--keep-scratch]

Run all lint rules against <defconfig>. Output is human-readable by default;
use --json for a machine-readable JSON array.

Rules are split into two tiers:
  Fast rules (L001/L002/L003, default): pure parsing of defconfig and the
  Kconfig tree. Cheap, always run.
  Deep rules (L004+, opt-in with --deep): shell out to `make` in the project
  root to run Kconfig operations like olddefconfig / savedefconfig. More
  expensive; require a working Kconfig toolchain in the target tree.

Deep rules write scratch files under $PWD/.kconform-tmp/ and clean them up on
exit. Pass --keep-scratch to preserve the scratch directory for inspection
(useful when investigating an unexpected finding). Add `.kconform-tmp/` to
your project's .gitignore if you run from a git working tree.

Exit codes:
  0  clean (zero errors)
  1  at least one finding of severity=error
  2  tool error (file missing, platform not detected, ...)
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform lint: unknown flag '$1'" >&2; return 2 ;;
            *)
                if [ -z "$defconfig" ]; then
                    defconfig="$1"
                else
                    echo "kconform lint: unexpected extra argument '$1'" >&2
                    return 2
                fi
                shift ;;
        esac
    done

    # Deep rules check these env vars to decide whether to execute and whether
    # to preserve their scratch directory on exit.
    export KCONFORM_DEEP="$deep"
    export KCONFORM_KEEP_SCRATCH="$keep_scratch"

    if [ -z "$defconfig" ]; then
        echo "kconform lint: missing <defconfig> argument" >&2
        return 2
    fi
    if [ ! -f "$defconfig" ]; then
        echo "kconform lint: '$defconfig': no such file" >&2
        return 2
    fi

    # Resolve project root: walk up from the defconfig's directory.
    local defconfig_dir
    defconfig_dir="$(cd "$(dirname "$defconfig")" && pwd)"
    local project_root platform
    if ! project_root="$(kconform_find_project_root "$defconfig_dir")"; then
        echo "kconform lint: could not detect platform near '$defconfig'" >&2
        echo "  Pass --platform=<name> to override autodetect." >&2
        return 2
    fi
    if [ -n "$platform_override" ]; then
        platform="$platform_override"
    else
        platform="$(kconform_detect_platform "$project_root")"
    fi

    local adapter="$KCONFORM_CLI_DIR/platforms/$platform.sh"
    if [ ! -f "$adapter" ]; then
        echo "kconform lint: no adapter for platform '$platform'" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$adapter"

    kconform_lint_run "$defconfig" "$project_root" "$platform" "$mode"
}

# Collects findings from every rule under cli/lib/lint-rules/, then formats.
kconform_lint_run() {
    local defconfig="$1"
    local project_root="$2"
    local platform="$3"
    local mode="$4"

    local rules_dir="$KCONFORM_CLI_DIR/lib/lint-rules"
    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    local rule_count=0
    local rule
    shopt -s nullglob
    for rule in "$rules_dir"/*.sh; do
        rule_count=$((rule_count + 1))
        bash "$rule" "$defconfig" "$project_root" "$platform" >>"$tmp" || true
    done
    shopt -u nullglob

    local findings_count error_count
    findings_count="$(grep -c '^{' "$tmp" 2>/dev/null || true)"
    findings_count="${findings_count:-0}"
    error_count="$(grep -c '"severity":"error"' "$tmp" 2>/dev/null || true)"
    error_count="${error_count:-0}"

    if [ "$mode" = "json" ]; then
        _kconform_lint_emit_json "$tmp"
    else
        _kconform_lint_emit_text "$tmp" "$defconfig" "$rule_count" "$findings_count"
    fi

    if [ "$error_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

_kconform_lint_emit_json() {
    local tmp="$1"
    local first=1
    printf '['
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ $first -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '%s' "$line"
    done <"$tmp"
    printf ']\n'
}

_kconform_lint_emit_text() {
    local tmp="$1"
    local defconfig="$2"
    local rule_count="$3"
    local findings_count="$4"

    printf 'kconform lint: %s\n' "$defconfig"

    if [ "$findings_count" -eq 0 ]; then
        printf '  clean — %d rule(s) ran, 0 findings\n' "$rule_count"
        return 0
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local rule severity symbol message fix
        rule="$(_kconform_json_get "$line" rule)"
        severity="$(_kconform_json_get "$line" severity)"
        symbol="$(_kconform_json_get "$line" symbol)"
        message="$(_kconform_json_get "$line" message)"
        fix="$(_kconform_json_get "$line" fix)"
        printf '  %-5s [%s] %s: %s\n' "$severity" "$rule" "$symbol" "$message"
        if [ -n "$fix" ]; then
            printf '         fix: %s\n' "$fix"
        fi
    done <"$tmp"

    printf '  %d finding(s), %d rule(s) ran\n' "$findings_count" "$rule_count"
}

# Flat-JSON value extractor. Handles simple {"k":"v","k2":"v2"} — no nested
# objects, no escaped quotes in values. Rule authors must therefore keep
# message / fix strings free of double quotes (use backticks, angle brackets,
# or plain prose instead). The `--json` output path emits raw rule lines and
# is unaffected by this limitation; only the human-readable text formatter
# calls this helper.
_kconform_json_get() {
    local line="$1"
    local key="$2"
    printf '%s' "$line" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p"
}
