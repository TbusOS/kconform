#!/usr/bin/env bash
# L001 ghost-symbol
#
# Detects CONFIG_X=<value> lines in a defconfig where X has no `config` or
# `menuconfig` definition anywhere in the Kconfig tree. Kconfig silently drops
# such lines at .config generation, so the feature never compiles in.
#
# Usage (invoked by cli/lib/lint.sh):
#     L001-ghost-symbol.sh <defconfig> <project_root> <platform>
#
# Output: one JSON object per finding on stdout.
# Exit: always 0 (the lint runner aggregates severity).

set -eu

defconfig="$1"
project_root="$2"
# platform argument is reserved for future per-platform tweaks; unused here.

# Collect the set of defined symbol names. We grep every file whose name starts
# with "Kconfig" under the project root. The pattern covers both keywords:
# `config FOO` and `menuconfig FOO` (they are semantically equivalent for our
# purposes — either one constitutes a valid definition).
defined_syms="$(mktemp)"
trap 'rm -f "$defined_syms"' EXIT

# Use -print0 / xargs -0 so filenames with spaces don't break the pipeline.
# `|| true` lets us continue when find/xargs find nothing.
find "$project_root" -type f -name 'Kconfig*' -print0 2>/dev/null \
    | xargs -0 -r grep -hE '^[[:space:]]*(menu)?config[[:space:]]+[A-Za-z0-9_]+' 2>/dev/null \
    | sed -E 's/^[[:space:]]*(menu)?config[[:space:]]+([A-Za-z0-9_]+).*/\2/' \
    | sort -u >"$defined_syms" || true

# Walk defconfig assignment lines: `CONFIG_FOO=y`, `CONFIG_FOO="str"`,
# `CONFIG_FOO=0x1000`, etc. Skip disable-marker lines (`# CONFIG_X is not set`)
# and blank/comment lines — those are L002's domain.
while IFS= read -r line; do
    case "$line" in
        CONFIG_*=*) : ;;
        *) continue ;;
    esac
    sym="${line#CONFIG_}"
    sym="${sym%%=*}"
    # Require at least one character and valid identifier shape.
    case "$sym" in
        ''|*[!A-Za-z0-9_]*) continue ;;
    esac
    if ! grep -qxF "$sym" "$defined_syms"; then
        printf '{"rule":"L001","severity":"error","symbol":"CONFIG_%s","message":"symbol has no config/menuconfig definition in the Kconfig tree","fix":"Define the symbol in a Kconfig file or remove the CONFIG_%s line from the defconfig."}\n' "$sym" "$sym"
    fi
done <"$defconfig"
