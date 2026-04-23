# cli/lib/symbol.sh — `kconform symbol <CONFIG_X>` implementation.
#
# Sourced by cli/kconform. Expects KCONFORM_CLI_DIR in env and detect.sh
# already sourced for platform autodetect.
#
# Looks up where CONFIG_X is defined in the Kconfig tree and prints:
#   - defined-at file:line
#   - type (bool | string | int | hex | tristate)
#   - prompt (short summary, from the `bool "..."` / `string "..."` form or
#     from an explicit `prompt "..."` line)
#   - default(s) — all `default` lines encountered, including conditional ones
#   - depends-on (joined with &&)
#   - select / imply lists
#   - first non-empty line of help text
#
# Scope note: this is a heuristic Kconfig parser — good enough for the common
# cases (simple bool/int/hex/string entries with literal defaults), not a
# full Kconfig expression engine. Complex `default ... if ...` chains are
# preserved verbatim rather than evaluated.

cmd_symbol() {
    local sym_input=""
    local mode="text"
    local platform_override=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) mode="json"; shift ;;
            --platform=*) platform_override="${1#--platform=}"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform symbol <CONFIG_X|X> [--platform=<name>] [--json]

Look up a Kconfig symbol's definition. Accepts either the full CONFIG_X
form or the bare X identifier.

Output (text):
  CONFIG_X
    defined at: <file>:<line>
    type:       <bool|string|int|hex|tristate>
    prompt:     "<short help>"
    default:    <value or expression>
    depends on: <expr>
    selects:    <Y, Z>
    implies:    <W>
    help:       <first line>

Exit codes:
  0  found
  1  symbol not defined anywhere in the Kconfig tree
  2  tool error (platform not detected, ...)
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform symbol: unknown flag '$1'" >&2; return 2 ;;
            *)
                if [ -z "$sym_input" ]; then
                    sym_input="$1"
                else
                    echo "kconform symbol: unexpected extra arg '$1'" >&2; return 2
                fi
                shift ;;
        esac
    done

    if [ -z "$sym_input" ]; then
        echo "kconform symbol: missing <CONFIG_X> argument" >&2
        echo "  Run 'kconform symbol --help' for details." >&2
        return 2
    fi

    # Normalize: accept CONFIG_X or plain X. We do our Kconfig search on the
    # bare identifier (without CONFIG_ prefix) because Kconfig files define
    # symbols as `config X`, not `config CONFIG_X`.
    local sym="${sym_input#CONFIG_}"
    case "$sym" in
        ''|*[!A-Za-z0-9_]*)
            echo "kconform symbol: '$sym_input' is not a valid symbol name" >&2
            return 2 ;;
    esac

    # Locate project root (same logic as lint / verify).
    local project_root platform
    if ! project_root="$(kconform_find_project_root "$PWD")"; then
        echo "kconform symbol: no supported platform detected at $PWD" >&2
        echo "  cd into a U-Boot tree or pass --platform=<name>." >&2
        return 2
    fi
    if [ -n "$platform_override" ]; then
        platform="$platform_override"
    else
        platform="$(kconform_detect_platform "$project_root")"
    fi

    local adapter="$KCONFORM_CLI_DIR/platforms/$platform.sh"
    if [ -f "$adapter" ]; then
        # shellcheck source=/dev/null
        source "$adapter"
    fi

    # Delegate the heavy lifting to an awk program. The awk script emits a
    # record per matching symbol definition. Fields are separated by ASCII
    # Unit Separator (\x1f, control char, never appears in Kconfig text).
    # Tabs were tempting but bash `read` treats tab as IFS-whitespace and
    # collapses consecutive tabs, silently losing empty fields.
    # Layout (9 fields):
    #   file | line | type | prompt | default | depends | select | imply | help
    # Multi-valued fields (default/select/imply) are joined with '|' inside.
    local result
    result="$(_kconform_symbol_lookup "$project_root" "$sym")"

    if [ -z "$result" ]; then
        if [ "$mode" = "json" ]; then
            printf '{"symbol":"CONFIG_%s","found":false}\n' "$sym"
        else
            printf 'kconform symbol: CONFIG_%s not defined in the Kconfig tree at %s\n' "$sym" "$project_root" >&2
        fi
        return 1
    fi

    if [ "$mode" = "json" ]; then
        _kconform_symbol_emit_json "$sym" "$result"
    else
        _kconform_symbol_emit_text "$sym" "$result"
    fi
    return 0
}

# Walks every Kconfig* file under <root> and parses the block(s) that define
# the named symbol. Emits one tab-separated record per definition found
# (a symbol can be declared in multiple files with distinct depends/defaults,
# which Kconfig merges — we print each site separately for transparency).
_kconform_symbol_lookup() {
    local root="$1"
    local target="$2"

    find "$root" -type f -name 'Kconfig*' -print0 2>/dev/null \
        | xargs -0 -r awk -v target="$target" '
        BEGIN {
            in_block = 0
            reset()
        }
        function reset() {
            block_file = ""
            block_line = 0
            block_type = ""
            block_prompt = ""
            block_defaults = ""
            block_depends = ""
            block_selects = ""
            block_implies = ""
            block_help = ""
            block_help_done = 0
            in_help = 0
            help_indent = 0
        }
        function flush() {
            if (in_block) {
                # \x1f = ASCII Unit Separator. Non-whitespace delimiter so
                # bash `read -r` preserves empty fields (see cmd_symbol).
                printf("%s\x1f%d\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n", \
                    block_file, block_line, block_type, block_prompt, \
                    block_defaults, block_depends, block_selects, \
                    block_implies, block_help)
            }
            in_block = 0
            reset()
        }
        function trim(s) {
            sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
            return s
        }
        function join_field(existing, addition,    sep) {
            if (existing == "") return addition
            return existing "|" addition
        }

        # Block opener: `config <target>` or `menuconfig <target>`
        match($0, /^[[:space:]]*(menu)?config[[:space:]]+[A-Za-z0-9_]+/) {
            tok = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*(menu)?config[[:space:]]+/, "", tok)
            if (tok == target) {
                flush()
                in_block = 1
                block_file = FILENAME
                block_line = FNR
                next
            } else if (in_block) {
                flush()
                next
            }
        }

        # Any structural keyword ends the current block.
        in_block && /^[[:space:]]*(menu|endmenu|choice|endchoice|if|endif|source|mainmenu|comment)([[:space:]]|$)/ {
            flush()
            next
        }

        # Inside a matching block: parse per-line attributes.
        in_block {
            line = $0

            # Help-text mode: indented lines belong to the help block. Stop
            # when indentation drops back or we hit a known attribute keyword.
            if (in_help) {
                if (line ~ /^[[:space:]]*$/) {
                    next
                }
                # Capture leading whitespace.
                match(line, /^[[:space:]]*/)
                cur_indent = RLENGTH
                if (help_indent == 0) help_indent = cur_indent
                if (cur_indent >= help_indent) {
                    if (!block_help_done) {
                        block_help = trim(line)
                        block_help_done = 1
                    }
                    next
                } else {
                    in_help = 0
                    # fall through to re-parse this line as an attribute
                }
            }

            if (match(line, /^[[:space:]]*(bool|string|int|hex|tristate)[[:space:]]*/)) {
                m = substr(line, RSTART, RLENGTH)
                sub(/^[[:space:]]+/, "", m); sub(/[[:space:]]+$/, "", m)
                block_type = m
                rest = substr(line, RSTART + RLENGTH)
                rest = trim(rest)
                if (rest ~ /^".*"/) {
                    match(rest, /"[^"]*"/)
                    block_prompt = substr(rest, RSTART + 1, RLENGTH - 2)
                }
                next
            }
            if (match(line, /^[[:space:]]*prompt[[:space:]]+/)) {
                rest = substr(line, RSTART + RLENGTH)
                rest = trim(rest)
                if (rest ~ /^".*"/) {
                    match(rest, /"[^"]*"/)
                    block_prompt = substr(rest, RSTART + 1, RLENGTH - 2)
                }
                next
            }
            if (match(line, /^[[:space:]]*default[[:space:]]+/)) {
                rest = trim(substr(line, RSTART + RLENGTH))
                sub(/[[:space:]]+#.*$/, "", rest)
                block_defaults = join_field(block_defaults, rest)
                next
            }
            if (match(line, /^[[:space:]]*depends[[:space:]]+on[[:space:]]+/)) {
                rest = trim(substr(line, RSTART + RLENGTH))
                sub(/[[:space:]]+#.*$/, "", rest)
                if (block_depends == "") block_depends = rest
                else block_depends = block_depends " && " rest
                next
            }
            if (match(line, /^[[:space:]]*select[[:space:]]+/)) {
                rest = trim(substr(line, RSTART + RLENGTH))
                sub(/[[:space:]]+#.*$/, "", rest)
                block_selects = join_field(block_selects, rest)
                next
            }
            if (match(line, /^[[:space:]]*imply[[:space:]]+/)) {
                rest = trim(substr(line, RSTART + RLENGTH))
                sub(/[[:space:]]+#.*$/, "", rest)
                block_implies = join_field(block_implies, rest)
                next
            }
            if (/^[[:space:]]*help[[:space:]]*$/ || /^[[:space:]]*---help---[[:space:]]*$/) {
                in_help = 1
                help_indent = 0
                next
            }
        }

        END { flush() }
    '
}

_kconform_symbol_emit_text() {
    local sym="$1"
    local records="$2"

    printf 'CONFIG_%s\n' "$sym"
    local first=1
    local rec
    while IFS= read -r rec; do
        [ -z "$rec" ] && continue
        if [ $first -eq 0 ]; then
            printf '  ---\n'
        fi
        first=0
        local file line type prompt defaults depends selects implies help
        IFS=$'\x1f' read -r file line type prompt defaults depends selects implies help <<<"$rec"
        printf '  defined at: %s:%s\n' "$file" "$line"
        [ -n "$type"     ] && printf '  type:       %s\n' "$type"
        [ -n "$prompt"   ] && printf '  prompt:     "%s"\n' "$prompt"
        if [ -n "$defaults" ]; then
            local d
            local first_d=1
            local defaults_arr
            IFS='|' read -ra defaults_arr <<<"$defaults"
            for d in "${defaults_arr[@]}"; do
                if [ $first_d -eq 1 ]; then
                    printf '  default:    %s\n' "$d"; first_d=0
                else
                    printf '              %s\n' "$d"
                fi
            done
        fi
        [ -n "$depends"  ] && printf '  depends on: %s\n' "$depends"
        if [ -n "$selects" ]; then
            local s_csv
            s_csv="$(printf '%s' "$selects" | tr '|' '\n' | paste -sd,)"
            printf '  selects:    %s\n' "${s_csv// ,/, }"
        fi
        if [ -n "$implies" ]; then
            local i_csv
            i_csv="$(printf '%s' "$implies" | tr '|' '\n' | paste -sd,)"
            printf '  implies:    %s\n' "${i_csv// ,/, }"
        fi
        [ -n "$help"     ] && printf '  help:       %s\n' "$help"
    done <<<"$records"
    # Explicit 0 return: the while loop's last `read` returns 1 on EOF,
    # which would propagate up under set -e and tank the caller.
    return 0
}

_kconform_symbol_emit_json() {
    local sym="$1"
    local records="$2"

    printf '{"symbol":"CONFIG_%s","found":true,"definitions":[' "$sym"
    local first=1
    local rec
    while IFS= read -r rec; do
        [ -z "$rec" ] && continue
        if [ $first -eq 0 ]; then printf ','; fi
        first=0
        local file line type prompt defaults depends selects implies help
        IFS=$'\x1f' read -r file line type prompt defaults depends selects implies help <<<"$rec"
        printf '{'
        printf '"defined_at":"%s:%s"' "$(_kconform_symbol_json_escape "$file")" "$line"
        [ -n "$type"    ] && printf ',"type":"%s"' "$type"
        [ -n "$prompt"  ] && printf ',"prompt":"%s"' "$(_kconform_symbol_json_escape "$prompt")"
        if [ -n "$defaults" ]; then
            printf ',"defaults":['
            _kconform_symbol_pipe_to_json_array "$defaults"
            printf ']'
        fi
        [ -n "$depends" ] && printf ',"depends_on":"%s"' "$(_kconform_symbol_json_escape "$depends")"
        if [ -n "$selects" ]; then
            printf ',"selects":['
            _kconform_symbol_pipe_to_json_array "$selects"
            printf ']'
        fi
        if [ -n "$implies" ]; then
            printf ',"implies":['
            _kconform_symbol_pipe_to_json_array "$implies"
            printf ']'
        fi
        [ -n "$help"    ] && printf ',"help":"%s"' "$(_kconform_symbol_json_escape "$help")"
        printf '}'
    done <<<"$records"
    printf ']}\n'
    # Explicit 0: same reason as _kconform_symbol_emit_text.
    return 0
}

_kconform_symbol_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

_kconform_symbol_pipe_to_json_array() {
    local joined="$1"
    local first=1
    local item
    IFS='|' read -ra arr <<<"$joined"
    for item in "${arr[@]}"; do
        if [ $first -eq 0 ]; then printf ','; fi
        first=0
        printf '"%s"' "$(_kconform_symbol_json_escape "$item")"
    done
}
