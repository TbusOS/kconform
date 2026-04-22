#!/usr/bin/env bash
# L002 non-standard-comment
#
# Flags lines that look like disable markers but are actually plain comments,
# of the form:
#
#   # CONFIG_X=y         ← L002 fires: Kconfig ignores this entirely
#   # CONFIG_X="str"     ← L002 fires: same
#   # CONFIG_X=0x1000    ← L002 fires: same
#
# The canonical disable form is `# CONFIG_X is not set` (literal string,
# no `=` sign). A line like `# CONFIG_X=y` is just a comment — the Kconfig
# parser skips it, and the symbol's effective value falls back to whatever
# `default` or `select` chain says. This is a classic foot-gun:
#
#   # Disabled for this board:
#   # CONFIG_SECURITY_FEATURE=y       ← author thinks this disables it
#
# …where the feature actually stays enabled because `default y` kicks in.
#
# Usage (invoked by cli/lib/lint.sh):
#     L002-non-standard-comment.sh <defconfig> <project_root> <platform>
#
# Output: one JSON object per finding on stdout, severity=warn.

set -eu

defconfig="$1"
# project_root / platform args reserved for future per-platform tweaks.

# Match: start-of-line, optional whitespace, '#', at least one whitespace,
# 'CONFIG_' + identifier + '=' + anything. Explicitly NOT matching
# '# CONFIG_X is not set' (no '=' between name and rest).
while IFS= read -r line; do
    case "$line" in
        \#*CONFIG_*=*) : ;;
        *) continue ;;
    esac
    # Strip leading '#' + whitespace to get the would-be assignment.
    stripped="${line#"${line%%[!#[:space:]]*}"}"
    case "$stripped" in
        CONFIG_*=*) : ;;
        *) continue ;;
    esac
    # Extract symbol name between CONFIG_ and =.
    sym="${stripped#CONFIG_}"
    sym="${sym%%=*}"
    case "$sym" in
        ''|*[!A-Za-z0-9_]*) continue ;;
    esac
    printf '{"rule":"L002","severity":"warn","symbol":"CONFIG_%s","message":"line looks like an enable directive but is a plain comment; Kconfig ignores it","fix":"To disable: write  # CONFIG_%s is not set  (Kconfig canonical form). To enable: remove the leading #. To drop the hint: delete the line."}\n' "$sym" "$sym"
done <"$defconfig"
