# cli/lib/fragment.sh — Kconfig fragment tooling.
#
# Sourced by cli/kconform. A "fragment" is a file containing Kconfig
# assignments meant to be layered on top of a base defconfig via
# merge_config.sh (or `kconform fragment apply`, once that lands). Fragments
# are the idiomatic way to express "board X plus security hardening" or
# "board X plus debug-build extras" without duplicating the whole defconfig.
#
# This file ships the subset of fragment verbs that need no make:
#   - new <name>        — write a commented empty template
#   - lint <frag>       — validate syntax line-by-line
#
# `apply`, `diff`, and `new --from-diff` land in later revisions and will
# be implemented alongside the existing scratch-dir machinery used by L004
# and verify.

cmd_fragment() {
    if [ $# -eq 0 ]; then
        _kconform_fragment_usage
        return 0
    fi
    local sub="$1"
    shift
    case "$sub" in
        new)    _kconform_fragment_new "$@" ;;
        lint)   _kconform_fragment_lint "$@" ;;
        apply)  _kconform_fragment_apply "$@" ;;
        diff)   _kconform_fragment_diff "$@" ;;
        -h|--help|help) _kconform_fragment_usage ;;
        *)
            echo "kconform fragment: unknown sub-command '$sub'" >&2
            echo "  Sub-commands: new | lint | apply | diff" >&2
            return 2 ;;
    esac
}

_kconform_fragment_usage() {
    cat <<'EOF'
kconform fragment <sub-command> [args]

Sub-commands:
  new <name>              Write a commented empty fragment template to
                          <name>.cfg (or exactly <name> if it already ends
                          in .cfg / .fragment).

  lint <frag>             Validate fragment syntax. A valid fragment
                          contains only these line shapes:
                            (blank)
                            # <arbitrary comment>
                            CONFIG_X=y | =n | =m | =<int> | =<hex> | ="str"
                            # CONFIG_X is not set
                          Anything else — in particular `# CONFIG_X=y`, a
                          common pseudo-disable — is flagged.

  apply <frag> <base>     Merge <frag> into <base> and produce the resulting
                          minimal defconfig. Runs `make olddefconfig` +
                          `make savedefconfig` in a scratch directory.
                          Use --out=<path> to write the result; default is
                          stdout.

  diff <f1> <f2>          Diff two fragments at the directive level
                          (`CONFIG_X=V` and `# CONFIG_X is not set`).
                          Report symbols only in f1, only in f2, or with
                          different directives in both.

Run `kconform fragment <sub-command> --help` for per-sub-command details.
EOF
}

# --- fragment new ---------------------------------------------------------

_kconform_fragment_new() {
    local name=""
    local force=0
    local from_diff_a=""
    local from_diff_b=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--force) force=1; shift ;;
            --from-diff)
                shift
                if [ $# -lt 2 ]; then
                    echo "kconform fragment new: --from-diff needs two paths (<cfg1> <cfg2>)" >&2
                    return 2
                fi
                from_diff_a="$1"; from_diff_b="$2"; shift 2 ;;
            -h|--help)
                cat <<'EOF'
kconform fragment new <name> [-f|--force] [--from-diff <cfg1> <cfg2>]

Write a fragment file at <name>.cfg. Two modes:

Default (empty):
  Emits a commented template listing the valid fragment line shapes.

--from-diff <cfg1> <cfg2>:
  Emits a fragment that captures the delta from <cfg1> to <cfg2>. For every
  directive in <cfg2> (enable or canonical disable) that is missing from
  <cfg1> or present with a different value, that directive is written into
  the fragment. Symbols present only in <cfg1> are NOT materialized as
  `# CONFIG_X is not set` — kconform cannot tell whether the absence in
  <cfg2> was intentional or just default.

-f | --force    Overwrite an existing file.
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform fragment new: unknown flag '$1'" >&2; return 2 ;;
            *)
                if [ -z "$name" ]; then name="$1"
                else echo "kconform fragment new: unexpected arg '$1'" >&2; return 2
                fi; shift ;;
        esac
    done

    if [ -z "$name" ]; then
        echo "kconform fragment new: missing <name> argument" >&2
        return 2
    fi

    local path="$name"
    case "$name" in
        *.cfg|*.fragment) : ;;
        *) path="${name}.cfg" ;;
    esac

    if [ -e "$path" ] && [ "$force" != "1" ]; then
        echo "kconform fragment new: '$path' already exists (use --force to overwrite)" >&2
        return 2
    fi

    # --from-diff mode: materialize the delta as a fragment.
    if [ -n "$from_diff_a" ]; then
        local f
        for f in "$from_diff_a" "$from_diff_b"; do
            if [ ! -f "$f" ]; then
                echo "kconform fragment new --from-diff: '$f': no such file" >&2
                return 2
            fi
        done
        _kconform_fragment_emit_from_diff "$from_diff_a" "$from_diff_b" "$path" || return $?
        return 0
    fi

    cat >"$path" <<'EOF'
# Kconfig fragment — generated by kconform fragment new.
#
# Layer this file on top of a base defconfig with either of:
#   scripts/kconfig/merge_config.sh configs/<board>_defconfig <this file>
#   kconform fragment apply <this file> configs/<board>_defconfig
#
# Syntax — use only these line shapes (replace <NAME> with a real symbol):
#   CONFIG_<NAME>=y                (enable a bool / tristate)
#   CONFIG_<NAME>=m                (enable a tristate as module)
#   CONFIG_<NAME>=<int>            (set an int symbol)
#   CONFIG_<NAME>=0x<hex>          (set a hex symbol)
#   CONFIG_<NAME>="string value"   (set a string symbol)
#   # CONFIG_<NAME> is not set     (canonical disable — note no '=')
#   # any plain comment            (documentation, free text)
#
# DO NOT write `# CONFIG_<NAME>=y` thinking it means "disable <NAME>" —
# Kconfig ignores that line entirely. Use `# CONFIG_<NAME> is not set`
# instead. (`kconform fragment lint` catches this mistake.)

# --- your assignments below ---
EOF

    echo "kconform fragment new: wrote '$path'"
}

# --- fragment lint --------------------------------------------------------

# Exit codes:
#   0  valid
#   1  one or more invalid lines
#   2  tool error (missing / unreadable file)
_kconform_fragment_lint() {
    local path=""
    local mode="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) mode="json"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform fragment lint <frag> [--json]

Validate fragment syntax. Prints one finding per non-conforming line.

Exit codes:
  0  fragment is syntactically clean
  1  at least one invalid line
  2  file missing or unreadable
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform fragment lint: unknown flag '$1'" >&2; return 2 ;;
            *)
                if [ -z "$path" ]; then path="$1"
                else echo "kconform fragment lint: unexpected arg '$1'" >&2; return 2
                fi; shift ;;
        esac
    done

    if [ -z "$path" ]; then
        echo "kconform fragment lint: missing <frag> argument" >&2
        return 2
    fi
    if [ ! -f "$path" ]; then
        echo "kconform fragment lint: '$path': no such file" >&2
        return 2
    fi

    # Accumulate findings to a temp file so we can emit in chosen format.
    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    local lineno=0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        _kconform_fragment_classify "$line" "$lineno" >>"$tmp"
    done <"$path"

    local invalid_count
    invalid_count=$(grep -c '"severity":"error"' "$tmp" 2>/dev/null || true)
    invalid_count="${invalid_count:-0}"
    local total_lines=$lineno

    if [ "$mode" = "json" ]; then
        _kconform_fragment_emit_json "$tmp" "$path" "$invalid_count" "$total_lines"
    else
        _kconform_fragment_emit_text "$tmp" "$path" "$invalid_count" "$total_lines"
    fi

    if [ "$invalid_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# Classify a single line. On invalid lines, emits a JSON finding to stdout.
# On valid lines, emits nothing.
_kconform_fragment_classify() {
    local line="$1"
    local lineno="$2"

    # Blank.
    case "$line" in
        ''|[[:space:]]*) ;;
    esac
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [ -z "$trimmed" ]; then
        return 0
    fi

    # Canonical disable: `# CONFIG_X is not set` (exactly — trailing text
    # other than optional trailing whitespace is an error).
    if [[ "$trimmed" =~ ^#[[:space:]]+CONFIG_[A-Za-z0-9_]+[[:space:]]+is[[:space:]]+not[[:space:]]+set$ ]]; then
        return 0
    fi

    # Pseudo-disable (`# CONFIG_X=...`) — invalid.
    if [[ "$trimmed" =~ ^#[[:space:]]+CONFIG_[A-Za-z0-9_]+= ]]; then
        local sym="${trimmed#\#}"
        sym="${sym#"${sym%%[![:space:]]*}"}"
        sym="${sym#CONFIG_}"
        sym="${sym%%=*}"
        printf '{"line":%d,"severity":"error","reason":"pseudo-disable","symbol":"CONFIG_%s","message":"`# CONFIG_X=...` is a plain comment; Kconfig ignores it. Use `# CONFIG_X is not set` to disable (no `=`)."}\n' "$lineno" "$sym"
        return 0
    fi

    # Plain comment.
    case "$trimmed" in
        \#*) return 0 ;;
    esac

    # Assignment: CONFIG_X=<value>
    if [[ "$trimmed" =~ ^CONFIG_[A-Za-z0-9_]+=.*$ ]]; then
        # Extract symbol and value. Minimal validation of the value — we
        # don't try to enforce type here since we don't know the Kconfig
        # type at fragment lint time. Just require that the symbol name is
        # a valid identifier (already enforced by regex above) and that
        # there's exactly one '=' before the value.
        local sym="${trimmed#CONFIG_}"
        sym="${sym%%=*}"
        case "$sym" in
            ''|[0-9]*)
                printf '{"line":%d,"severity":"error","reason":"bad-symbol","symbol":"CONFIG_%s","message":"symbol name must start with a letter or underscore"}\n' "$lineno" "$sym"
                return 0 ;;
        esac
        return 0
    fi

    # Anything else is unrecognized.
    local snippet="${trimmed:0:60}"
    # Strip double quotes from snippet so our JSON doesn't need escaping.
    snippet="${snippet//\"/\'}"
    snippet="${snippet//\\/\/}"
    printf '{"line":%d,"severity":"error","reason":"unrecognized","snippet":"%s","message":"line matches no valid fragment form (blank, comment, CONFIG_X=..., or `# CONFIG_X is not set`)"}\n' "$lineno" "$snippet"
}

_kconform_fragment_emit_text() {
    local tmp="$1"
    local path="$2"
    local invalid="$3"
    local total="$4"

    printf 'kconform fragment lint: %s\n' "$path"
    if [ "$invalid" -eq 0 ]; then
        printf '  clean — %d line(s) checked, 0 issues\n' "$total"
        return 0
    fi

    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local lineno reason symbol snippet message
        lineno="$(printf '%s' "$line" | sed -n 's/.*"line":\([0-9]*\).*/\1/p')"
        reason="$(printf '%s' "$line"  | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')"
        symbol="$(printf '%s' "$line"  | sed -n 's/.*"symbol":"\([^"]*\)".*/\1/p')"
        snippet="$(printf '%s' "$line" | sed -n 's/.*"snippet":"\([^"]*\)".*/\1/p')"
        message="$(printf '%s' "$line" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')"

        local subject=""
        if [ -n "$symbol" ]; then subject="$symbol"
        elif [ -n "$snippet" ]; then subject="\"$snippet\""
        else subject="-"
        fi
        printf '  error line %s [%s] %s: %s\n' "$lineno" "$reason" "$subject" "$message"
    done <"$tmp"

    printf '  %d invalid line(s) out of %d total\n' "$invalid" "$total"
    return 0
}

_kconform_fragment_emit_json() {
    local tmp="$1"
    local path="$2"
    local invalid="$3"
    local total="$4"

    printf '{"file":"%s","total_lines":%d,"invalid_lines":%d,"findings":[' \
        "$(_kconform_fragment_json_escape "$path")" "$total" "$invalid"
    local first=1
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ $first -eq 0 ]; then printf ','; fi
        first=0
        printf '%s' "$line"
    done <"$tmp"
    printf ']}\n'
    return 0
}

_kconform_fragment_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# --- fragment apply -------------------------------------------------------

_kconform_fragment_apply() {
    local frag=""
    local base=""
    local out_path=""
    local platform_override=""
    local keep_scratch="0"
    local mode="text"

    while [ $# -gt 0 ]; do
        case "$1" in
            --out=*) out_path="${1#--out=}"; shift ;;
            --platform=*) platform_override="${1#--platform=}"; shift ;;
            --keep-scratch) keep_scratch="1"; shift ;;
            --json) mode="json"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform fragment apply <frag> <base> [--out=<path>] [--platform=<name>] [--keep-scratch] [--json]

Merge <frag> into <base>, run `make olddefconfig` and `make savedefconfig`
in a scratch directory, and emit the resulting minimal defconfig.

Output:
  Default (text):  the minimal defconfig on stdout, a summary on stderr.
  --out=<path>:    writes the minimal defconfig to <path>; summary on stdout.
  --json:          structured verdict on stdout (no defconfig body).

Summary reports, at the .config level (i.e. effective behavior after
olddefconfig), how many symbols the fragment added / removed / changed
relative to <base>.

Scratch directory: $PWD/.kconform-tmp/fragment-apply-<pid>-<ts>/
Cleaned on exit unless --keep-scratch or a make step fails.

Exit codes:
  0  applied successfully
  1  make step failed (scratch is preserved for inspection)
  2  tool error (file missing, platform not detected, ...)
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform fragment apply: unknown flag '$1'" >&2; return 2 ;;
            *)
                if [ -z "$frag" ]; then frag="$1"
                elif [ -z "$base" ]; then base="$1"
                else echo "kconform fragment apply: unexpected arg '$1'" >&2; return 2
                fi; shift ;;
        esac
    done

    if [ -z "$frag" ] || [ -z "$base" ]; then
        echo "kconform fragment apply: need both <frag> and <base>" >&2
        echo "  Run 'kconform fragment apply --help' for details." >&2
        return 2
    fi
    local f
    for f in "$frag" "$base"; do
        if [ ! -f "$f" ]; then
            echo "kconform fragment apply: '$f': no such file" >&2
            return 2
        fi
    done

    # Resolve absolute paths before any cd.
    frag="$(cd "$(dirname "$frag")" && pwd)/$(basename "$frag")"
    base="$(cd "$(dirname "$base")" && pwd)/$(basename "$base")"

    # Detect project root from <base>'s directory.
    local project_root platform
    local base_dir
    base_dir="$(dirname "$base")"
    if ! project_root="$(kconform_find_project_root "$base_dir")"; then
        echo "kconform fragment apply: could not detect project root near '$base'" >&2
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
        echo "kconform fragment apply: no adapter for platform '$platform'" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$adapter"

    # Scratch setup — same policy as L004 / verify.
    local scratch_base="$PWD/.kconform-tmp"
    local scratch="$scratch_base/fragment-apply-$$-$(date +%s)"
    local scratch_base_cfg="$scratch/base"
    local scratch_merged="$scratch/merged"
    mkdir -p "$scratch_base_cfg" "$scratch_merged"

    # shellcheck disable=SC2064
    if [ "$keep_scratch" = "1" ]; then
        trap "printf 'kconform fragment apply: scratch preserved at %s\\n' '$scratch' >&2" EXIT
    else
        trap "rm -rf '$scratch'; rmdir '$scratch_base' 2>/dev/null || true" EXIT
    fi

    # Stage base.
    cp "$base" "$scratch_base_cfg/.config"
    # Stage merged: copy base then apply fragment on top.
    cp "$base" "$scratch_merged/.config"
    _kconform_fragment_merge_into "$frag" "$scratch_merged/.config"

    # Normalize both sides via olddefconfig so the diff is semantic, not
    # cosmetic.
    if ! make -C "$project_root" O="$scratch_base_cfg" olddefconfig \
           >"$scratch_base_cfg/make.log" 2>&1; then
        trap - EXIT
        echo "kconform fragment apply: make olddefconfig failed on <base>" >&2
        echo "  see $scratch_base_cfg/make.log" >&2
        return 1
    fi
    if ! make -C "$project_root" O="$scratch_merged" olddefconfig \
           >"$scratch_merged/make.log" 2>&1; then
        trap - EXIT
        echo "kconform fragment apply: make olddefconfig failed on merged" >&2
        echo "  see $scratch_merged/make.log" >&2
        return 1
    fi
    if ! make -C "$project_root" O="$scratch_merged" savedefconfig \
           >>"$scratch_merged/make.log" 2>&1; then
        trap - EXIT
        echo "kconform fragment apply: make savedefconfig failed on merged" >&2
        echo "  see $scratch_merged/make.log" >&2
        return 1
    fi

    # Compute semantic delta at the .config level: compare sorted semantic
    # lines (CONFIG_X=... and # CONFIG_X is not set).
    local base_norm="$scratch/base.norm"
    local merged_norm="$scratch/merged.norm"
    grep -E '^(CONFIG_|# CONFIG_)' "$scratch_base_cfg/.config" | LC_ALL=C sort >"$base_norm" || true
    grep -E '^(CONFIG_|# CONFIG_)' "$scratch_merged/.config"  | LC_ALL=C sort >"$merged_norm"  || true

    local added removed changed
    added=$(mktemp -p "$scratch" added.XXXXXX)
    removed=$(mktemp -p "$scratch" removed.XXXXXX)
    changed=$(mktemp -p "$scratch" changed.XXXXXX)
    _kconform_fragment_classify_delta "$base_norm" "$merged_norm" "$added" "$removed" "$changed"

    local added_count removed_count changed_count
    added_count=$(wc -l <"$added" | tr -d ' ')
    removed_count=$(wc -l <"$removed" | tr -d ' ')
    changed_count=$(wc -l <"$changed" | tr -d ' ')

    # Emit the resulting minimal defconfig.
    if [ -n "$out_path" ]; then
        cp "$scratch_merged/defconfig" "$out_path"
    fi

    if [ "$mode" = "json" ]; then
        _kconform_fragment_apply_emit_json \
            "$frag" "$base" "$out_path" \
            "$added" "$removed" "$changed" \
            "$scratch_merged/defconfig"
    else
        if [ -z "$out_path" ]; then
            # defconfig body to stdout; summary to stderr.
            cat "$scratch_merged/defconfig"
        fi
        {
            printf 'kconform fragment apply: %s + %s\n' "$base" "$frag"
            printf '  added:   %s symbol(s)\n' "$added_count"
            printf '  removed: %s symbol(s)\n' "$removed_count"
            printf '  changed: %s symbol(s)\n' "$changed_count"
            if [ -n "$out_path" ]; then
                printf '  wrote minimal defconfig to: %s\n' "$out_path"
            fi
            if [ "$keep_scratch" = "1" ]; then
                printf '  scratch preserved at: %s\n' "$scratch"
            fi
        } >&2
    fi

    return 0
}

# Append/replace lines from <frag> into <target> (the merged .config). Any
# fragment line that sets or disables a CONFIG_X will first delete any
# existing entry for CONFIG_X in <target>, then append the new directive.
# Plain comments, blanks, and unrecognized lines in the fragment are skipped
# (fragment lint is the proper place to surface those as errors).
_kconform_fragment_merge_into() {
    local frag="$1"
    local target="$2"

    local tmp="${target}.merge.tmp"
    cp "$target" "$tmp"

    local line sym
    while IFS= read -r line || [ -n "$line" ]; do
        sym=""
        if [[ "$line" =~ ^CONFIG_([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            sym="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^#[[:space:]]+CONFIG_([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+is[[:space:]]+not[[:space:]]+set[[:space:]]*$ ]]; then
            sym="${BASH_REMATCH[1]}"
        else
            continue
        fi
        # Delete any existing entry for CONFIG_<sym> in tmp — both
        # enable-form and canonical-disable-form.
        sed -i "/^CONFIG_${sym}=/d" "$tmp"
        sed -i "/^# CONFIG_${sym} is not set$/d" "$tmp"
        # Append the new directive.
        printf '%s\n' "$line" >>"$tmp"
    done <"$frag"

    mv "$tmp" "$target"
}

# Given sorted semantic lines from base and merged, compute three classes:
#   added    — CONFIG_X present in merged but not base
#   removed  — CONFIG_X present in base but not merged
#   changed  — CONFIG_X present in both with different directive
# Each output file contains one CONFIG_X per line (enable form or
# canonical disable as it appears in that file).
_kconform_fragment_classify_delta() {
    local base_norm="$1"
    local merged_norm="$2"
    local added_out="$3"
    local removed_out="$4"
    local changed_out="$5"

    local base_syms="$(mktemp)"
    local merged_syms="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$base_syms' '$merged_syms'" RETURN

    # Extract just the symbol name from each line for set-membership compare.
    sed -E 's/^(CONFIG_|# CONFIG_)([A-Za-z0-9_]+).*/\2/' "$base_norm"   | LC_ALL=C sort -u >"$base_syms"
    sed -E 's/^(CONFIG_|# CONFIG_)([A-Za-z0-9_]+).*/\2/' "$merged_norm" | LC_ALL=C sort -u >"$merged_syms"

    # added = in merged, not in base
    LC_ALL=C comm -13 "$base_syms" "$merged_syms" \
        | sed 's/^/CONFIG_/' >"$added_out"
    # removed = in base, not in merged
    LC_ALL=C comm -23 "$base_syms" "$merged_syms" \
        | sed 's/^/CONFIG_/' >"$removed_out"
    # changed = in both, directive text differs
    local common_syms
    common_syms="$(mktemp)"
    LC_ALL=C comm -12 "$base_syms" "$merged_syms" >"$common_syms"
    : >"$changed_out"
    local sym base_dir merged_dir
    while IFS= read -r sym; do
        [ -z "$sym" ] && continue
        base_dir="$(grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$base_norm"   | head -n1)"
        merged_dir="$(grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$merged_norm" | head -n1)"
        if [ "$base_dir" != "$merged_dir" ]; then
            printf 'CONFIG_%s\n' "$sym" >>"$changed_out"
        fi
    done <"$common_syms"
    rm -f "$common_syms"
}

_kconform_fragment_apply_emit_json() {
    local frag="$1"; local base="$2"; local out_path="$3"
    local added="$4"; local removed="$5"; local changed="$6"
    local defconfig_path="$7"

    printf '{"applied":true'
    printf ',"fragment":"%s"' "$(_kconform_fragment_json_escape "$frag")"
    printf ',"base":"%s"' "$(_kconform_fragment_json_escape "$base")"
    if [ -n "$out_path" ]; then
        printf ',"out":"%s"' "$(_kconform_fragment_json_escape "$out_path")"
    fi
    printf ',"added":'
    _kconform_fragment_file_to_json_array "$added"
    printf ',"removed":'
    _kconform_fragment_file_to_json_array "$removed"
    printf ',"changed":'
    _kconform_fragment_file_to_json_array "$changed"
    printf '}\n'
    return 0
}

_kconform_fragment_file_to_json_array() {
    local file="$1"
    if [ ! -s "$file" ]; then
        printf '[]'
        return
    fi
    printf '['
    local first=1
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ $first -eq 0 ]; then printf ','; fi
        first=0
        printf '"%s"' "$(_kconform_fragment_json_escape "$line")"
    done <"$file"
    printf ']'
}

# --- fragment diff / new --from-diff: shared parser + logic --------------

# Parse a fragment / .config / defconfig into a TSV of "symbol<TAB>directive"
# for every enable-form (`CONFIG_X=V`) and canonical-disable line (`# CONFIG_X
# is not set`). Output is sorted by symbol and deduped. Comments, blanks, and
# pseudo-disable lines are ignored.
_kconform_fragment_parse_directives() {
    local file="$1"
    local out="$2"

    awk '
    /^CONFIG_[A-Za-z_][A-Za-z0-9_]*=/ {
        line = $0
        sym = $0
        sub(/=.*/, "", sym)
        sub(/^CONFIG_/, "", sym)
        print sym "\t" line
        next
    }
    /^#[[:space:]]+CONFIG_[A-Za-z_][A-Za-z0-9_]*[[:space:]]+is[[:space:]]+not[[:space:]]+set[[:space:]]*$/ {
        line = $0
        sym = $0
        sub(/^#[[:space:]]+CONFIG_/, "", sym)
        sub(/[[:space:]]+is.*/, "", sym)
        print sym "\t" line
        next
    }
    ' "$file" | LC_ALL=C sort -u >"$out"
}

# Emit a fragment at <out_path> containing every directive present in <b> that
# is absent from or differs against <a>. Symbols in <a> but not <b> are NOT
# emitted — we can't infer <b>'s intent from the absence.
_kconform_fragment_emit_from_diff() {
    local a="$1"
    local b="$2"
    local out_path="$3"

    local ta tb
    ta="$(mktemp)"; tb="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$ta' '$tb'" RETURN

    _kconform_fragment_parse_directives "$a" "$ta"
    _kconform_fragment_parse_directives "$b" "$tb"

    # A directive from b is "new or changed" if the exact TSV row from b does
    # not appear in a (that covers both "symbol not in a" and "symbol with
    # different value in a"). comm -13 a b → lines only in b.
    local to_emit_tsv
    to_emit_tsv="$(mktemp)"
    LC_ALL=C comm -13 "$ta" "$tb" >"$to_emit_tsv"

    {
        printf '# Kconfig fragment — generated by `kconform fragment new --from-diff`.\n'
        printf '#\n'
        printf '# Source:\n'
        printf '#   a = %s\n' "$a"
        printf '#   b = %s\n' "$b"
        printf '#\n'
        printf '# Contents: every directive from <b> that is missing or differs in <a>.\n'
        printf '# Applying this fragment on top of <a> produces a config that matches <b>\n'
        printf '# on the symbols <b> sets explicitly. Symbols present only in <a> are not\n'
        printf '# emitted — kconform cannot tell whether <b> intentionally left them off or\n'
        printf '# the minimization step just dropped a default-matching line.\n'
        printf '\n'
        cut -f2- "$to_emit_tsv"
    } >"$out_path"

    local count
    count=$(wc -l <"$to_emit_tsv" | tr -d ' ')
    printf 'kconform fragment new --from-diff: wrote %s directive(s) to %s\n' "$count" "$out_path"

    rm -f "$to_emit_tsv"
    return 0
}

# --- fragment diff -------------------------------------------------------

_kconform_fragment_diff() {
    local f1=""
    local f2=""
    local mode="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) mode="json"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform fragment diff <f1> <f2> [--json]

Compare two fragment files at the directive level. Reports:
  only in <f1>:   symbols with a directive in f1, none in f2
  only in <f2>:   symbols with a directive in f2, none in f1
  differs:        symbol has a directive in both, but the directive lines
                  do not match (enable ↔ disable, or different values)

Comments, blank lines, and pseudo-disable lines (`# CONFIG_X=y`) are
ignored — run `kconform fragment lint` first if you need to validate
fragment syntax.

Exit codes:
  0  fragments are equivalent (every symbol has the same directive, if any)
  1  fragments differ
  2  tool error (file missing, ...)
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform fragment diff: unknown flag '$1'" >&2; return 2 ;;
            *)
                if [ -z "$f1" ]; then f1="$1"
                elif [ -z "$f2" ]; then f2="$1"
                else echo "kconform fragment diff: unexpected arg '$1'" >&2; return 2
                fi; shift ;;
        esac
    done

    if [ -z "$f1" ] || [ -z "$f2" ]; then
        echo "kconform fragment diff: need two fragment paths" >&2
        return 2
    fi
    local f
    for f in "$f1" "$f2"; do
        if [ ! -f "$f" ]; then
            echo "kconform fragment diff: '$f': no such file" >&2
            return 2
        fi
    done

    local t1 t2
    t1="$(mktemp)"; t2="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$t1' '$t2'" RETURN

    _kconform_fragment_parse_directives "$f1" "$t1"
    _kconform_fragment_parse_directives "$f2" "$t2"

    # Symbols only in t1 (full directive comparison, not just symbol key).
    # For "only-in" semantics we need symbol-key comparison (if a symbol is in
    # both but with different directive, it's "differs", not "only-in-X").
    local syms1 syms2
    syms1="$(mktemp)"; syms2="$(mktemp)"
    cut -f1 "$t1" >"$syms1"
    cut -f1 "$t2" >"$syms2"

    local only1_syms only2_syms both_syms
    only1_syms="$(mktemp)"; only2_syms="$(mktemp)"; both_syms="$(mktemp)"
    LC_ALL=C comm -23 "$syms1" "$syms2" >"$only1_syms"
    LC_ALL=C comm -13 "$syms1" "$syms2" >"$only2_syms"
    LC_ALL=C comm -12 "$syms1" "$syms2" >"$both_syms"

    # For symbols in both, find those with differing directives.
    local differs_syms
    differs_syms="$(mktemp)"
    local sym d1 d2
    while IFS= read -r sym; do
        [ -z "$sym" ] && continue
        d1=$(grep -F -m1 "${sym}"$'\t' "$t1" | cut -f2)
        d2=$(grep -F -m1 "${sym}"$'\t' "$t2" | cut -f2)
        if [ "$d1" != "$d2" ]; then
            printf 'CONFIG_%s\n' "$sym" >>"$differs_syms"
        fi
    done <"$both_syms"

    # Decorate only-in outputs with CONFIG_ prefix for consistency.
    sed 's/^/CONFIG_/' "$only1_syms" >"${only1_syms}.out"
    sed 's/^/CONFIG_/' "$only2_syms" >"${only2_syms}.out"

    local o1_n o2_n dif_n
    o1_n=$(wc -l <"${only1_syms}.out" | tr -d ' ')
    o2_n=$(wc -l <"${only2_syms}.out" | tr -d ' ')
    dif_n=$(wc -l <"$differs_syms" | tr -d ' ')
    local total=$((o1_n + o2_n + dif_n))

    if [ "$mode" = "json" ]; then
        printf '{"f1":"%s","f2":"%s"' \
            "$(_kconform_fragment_json_escape "$f1")" \
            "$(_kconform_fragment_json_escape "$f2")"
        printf ',"equivalent":%s' "$([ $total -eq 0 ] && printf 'true' || printf 'false')"
        printf ',"only_in_f1":'
        _kconform_fragment_file_to_json_array "${only1_syms}.out"
        printf ',"only_in_f2":'
        _kconform_fragment_file_to_json_array "${only2_syms}.out"
        printf ',"differs":'
        _kconform_fragment_file_to_json_array "$differs_syms"
        printf '}\n'
    else
        printf 'kconform fragment diff: %s vs %s\n' "$f1" "$f2"
        if [ "$total" -eq 0 ]; then
            printf '  equivalent — same directives in both\n'
        else
            printf '  only in <f1>: %s symbol(s)\n' "$o1_n"
            [ "$o1_n" -gt 0 ] && sed 's/^/    - /' "${only1_syms}.out"
            printf '  only in <f2>: %s symbol(s)\n' "$o2_n"
            [ "$o2_n" -gt 0 ] && sed 's/^/    + /' "${only2_syms}.out"
            printf '  differs:      %s symbol(s)\n' "$dif_n"
            [ "$dif_n" -gt 0 ] && sed 's/^/    ~ /' "$differs_syms"
        fi
    fi

    rm -f "$syms1" "$syms2" "$only1_syms" "$only2_syms" "$both_syms" \
          "${only1_syms}.out" "${only2_syms}.out" "$differs_syms"

    if [ "$total" -gt 0 ]; then
        return 1
    fi
    return 0
}
