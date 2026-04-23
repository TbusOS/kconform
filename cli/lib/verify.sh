# cli/lib/verify.sh — defconfig equivalence verification.
#
# Sourced by cli/kconform. Expects KCONFORM_ROOT / KCONFORM_CLI_DIR in env
# and detect.sh already sourced (for platform adapter discovery).
#
# Algorithm (see DESIGN §4.4):
#   1. If <before> and <after> are byte-identical, short-circuit to equivalent.
#   2. Otherwise: create a scratch dir per side under $PWD/.kconform-tmp/,
#      copy each defconfig to scratch/.config, run `make O=... olddefconfig`.
#   3. Extract semantic lines (`^CONFIG_` + `^# CONFIG_...is not set`) from
#      each resulting .config, sort, compare.
#   4. Report symbols present-only-in-before (removed) and present-only-in-
#      after (added). Same key with different values shows up as one of each.
#   5. Exit 0 if equivalent, 1 on semantic-change, 2 on tool error.

cmd_verify() {
    local before=""
    local after=""
    local mode="text"
    local platform_override=""
    local keep_scratch="0"

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) mode="json"; shift ;;
            --platform=*) platform_override="${1#--platform=}"; shift ;;
            --keep-scratch) keep_scratch="1"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform verify <before> <after> [--platform=<name>] [--json] [--keep-scratch]

Prove or disprove that two defconfig files produce equivalent .config output.

Algorithm:
  1. Short-circuit: if the two files are byte-identical, return equivalent.
  2. Otherwise: run `make olddefconfig` for each in a scratch directory,
     then compare the resulting .config files on semantic lines only
     (CONFIG_X=... and # CONFIG_X is not set). Comments and blank lines
     are ignored.

This catches the common "I rewrote/minimized/ported a defconfig — did I
change any behavior?" question, which is the primary SDK-migration use
case. Reports the symbols that differ so you can see exactly what
changed.

Exit codes:
  0  equivalent (no semantic difference)
  1  semantic difference (one or more symbols differ)
  2  tool error (file missing, platform not detected, make failed, ...)
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform verify: unknown flag '$1'" >&2; return 2 ;;
            *)
                if [ -z "$before" ]; then
                    before="$1"
                elif [ -z "$after" ]; then
                    after="$1"
                else
                    echo "kconform verify: unexpected extra argument '$1'" >&2
                    return 2
                fi
                shift ;;
        esac
    done

    if [ -z "$before" ] || [ -z "$after" ]; then
        echo "kconform verify: need <before> and <after> defconfig paths" >&2
        echo "  Run 'kconform verify --help' for details." >&2
        return 2
    fi
    local f
    for f in "$before" "$after"; do
        if [ ! -f "$f" ]; then
            echo "kconform verify: '$f': no such file" >&2
            return 2
        fi
    done

    # Short-circuit: byte-identical inputs → trivially equivalent.
    if cmp -s "$before" "$after"; then
        if [ "$mode" = "json" ]; then
            printf '{"verdict":"equivalent","reason":"defconfigs are byte-identical","before_only":[],"after_only":[]}\n'
        else
            printf 'kconform verify: equivalent\n'
            printf '  reason: defconfigs are byte-identical\n'
        fi
        return 0
    fi

    # Resolve absolute paths BEFORE any cd happens inside helpers.
    before="$(cd "$(dirname "$before")" && pwd)/$(basename "$before")"
    after="$(cd "$(dirname "$after")" && pwd)/$(basename "$after")"

    # Detect platform from the <before> defconfig's directory.
    local project_root platform
    local before_dir
    before_dir="$(dirname "$before")"
    if ! project_root="$(kconform_find_project_root "$before_dir")"; then
        echo "kconform verify: could not detect platform near '$before'" >&2
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
        echo "kconform verify: no adapter for platform '$platform'" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$adapter"

    # Scratch directories: one per side, under $PWD/.kconform-tmp/ (never /tmp).
    local scratch_base="$PWD/.kconform-tmp"
    local scratch="$scratch_base/verify-$$-$(date +%s)"
    local scratch_before="$scratch/before"
    local scratch_after="$scratch/after"
    mkdir -p "$scratch_before" "$scratch_after"

    # Cleanup on exit unless user asked to keep scratch OR make failed
    # (we leave scratch in place on make failure so the user can read logs).
    # shellcheck disable=SC2317
    _kconform_verify_cleanup() {
        if [ "$keep_scratch" = "1" ]; then
            return
        fi
        rm -rf "$scratch"
        rmdir "$scratch_base" 2>/dev/null || true
    }
    trap _kconform_verify_cleanup EXIT

    cp "$before" "$scratch_before/.config"
    cp "$after"  "$scratch_after/.config"

    if ! make -C "$project_root" O="$scratch_before" olddefconfig \
           >"$scratch_before/make.log" 2>&1; then
        trap - EXIT
        echo "kconform verify: make olddefconfig failed on <before>" >&2
        echo "  see $scratch_before/make.log" >&2
        return 2
    fi
    if ! make -C "$project_root" O="$scratch_after" olddefconfig \
           >"$scratch_after/make.log" 2>&1; then
        trap - EXIT
        echo "kconform verify: make olddefconfig failed on <after>" >&2
        echo "  see $scratch_after/make.log" >&2
        return 2
    fi

    # Extract semantic lines: CONFIG_X=... (enabled, with value) and
    # # CONFIG_X is not set (canonical disable). Sort for set comparison.
    local before_norm="$scratch/before.norm"
    local after_norm="$scratch/after.norm"
    grep -E '^(CONFIG_|# CONFIG_)' "$scratch_before/.config" | LC_ALL=C sort >"$before_norm" || true
    grep -E '^(CONFIG_|# CONFIG_)' "$scratch_after/.config"  | LC_ALL=C sort >"$after_norm"  || true

    if cmp -s "$before_norm" "$after_norm"; then
        if [ "$mode" = "json" ]; then
            printf '{"verdict":"equivalent","reason":".config byte-identical after olddefconfig roundtrip","before_only":[],"after_only":[]}\n'
        else
            printf 'kconform verify: equivalent\n'
            printf '  before: %s\n' "$before"
            printf '  after:  %s\n' "$after"
            printf '  .config outputs match after olddefconfig roundtrip.\n'
        fi
        return 0
    fi

    # Compute lines only-in-before and only-in-after.
    local before_only="$scratch/before-only.lines"
    local after_only="$scratch/after-only.lines"
    comm -23 "$before_norm" "$after_norm" >"$before_only"
    comm -13 "$before_norm" "$after_norm" >"$after_only"

    local before_only_count after_only_count
    before_only_count=$(wc -l <"$before_only" | tr -d ' ')
    after_only_count=$(wc -l <"$after_only" | tr -d ' ')

    if [ "$mode" = "json" ]; then
        _kconform_verify_emit_json "$before_only" "$after_only"
    else
        printf 'kconform verify: semantic-change\n'
        printf '  before: %s\n' "$before"
        printf '  after:  %s\n' "$after"
        printf '  lines only in <before>: %s\n' "$before_only_count"
        if [ "$before_only_count" -gt 0 ]; then
            sed 's/^/    - /' "$before_only"
        fi
        printf '  lines only in <after>:  %s\n' "$after_only_count"
        if [ "$after_only_count" -gt 0 ]; then
            sed 's/^/    + /' "$after_only"
        fi
        if [ "$keep_scratch" = "1" ]; then
            printf '  scratch preserved at %s\n' "$scratch"
        else
            printf '  pass --keep-scratch to retain the scratch dir at %s\n' "$scratch"
        fi
    fi
    return 1
}

# Emits a compact JSON verdict for semantic-change case. The input files
# contain one .config line per row, already sorted. Lines may contain
# double-quotes (rare — inside CONFIG_STRING_VAR="..." values) which we
# escape for JSON safety.
_kconform_verify_emit_json() {
    local before_only="$1"
    local after_only="$2"
    printf '{"verdict":"semantic-change","before_only":'
    _kconform_verify_lines_to_json_array "$before_only"
    printf ',"after_only":'
    _kconform_verify_lines_to_json_array "$after_only"
    printf '}\n'
}

_kconform_verify_lines_to_json_array() {
    local file="$1"
    if [ ! -s "$file" ]; then
        printf '[]'
        return
    fi
    printf '['
    local first=1
    local line
    while IFS= read -r line; do
        if [ $first -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        # Escape backslash, then double-quote, then control chars. The .config
        # output never has real newlines in values (Kconfig forbids), so we
        # don't need to handle \n.
        line="${line//\\/\\\\}"
        line="${line//\"/\\\"}"
        printf '"%s"' "$line"
    done <"$file"
    printf ']'
}
