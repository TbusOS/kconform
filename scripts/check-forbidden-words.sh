#!/usr/bin/env bash
# scripts/check-forbidden-words.sh — grep committed files against
# .forbidden-words. Intended to run in CI and as a pre-commit hook.
#
# Usage:
#   scripts/check-forbidden-words.sh               # scan tracked files
#   scripts/check-forbidden-words.sh <files...>    # scan specific files

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATTERN_FILE="$REPO_ROOT/.forbidden-words"

if [ ! -f "$PATTERN_FILE" ]; then
    echo "error: $PATTERN_FILE missing" >&2
    exit 2
fi

# Collect patterns into an array (strip blanks and comments).
patterns=()
while IFS= read -r line; do
    case "$line" in
        ''|'#'*) continue ;;
    esac
    patterns+=("$line")
done <"$PATTERN_FILE"

if [ ${#patterns[@]} -eq 0 ]; then
    echo "no patterns to check (empty .forbidden-words)"
    exit 0
fi

# Determine file list.
files=()
if [ $# -gt 0 ]; then
    files=("$@")
else
    # All git-tracked files, excluding the pattern file itself and the
    # scanner script (which legitimately contain the strings).
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ "$f" = ".forbidden-words" ] && continue
        [ "$f" = "scripts/check-forbidden-words.sh" ] && continue
        files+=("$f")
    done < <(cd "$REPO_ROOT" && git ls-files 2>/dev/null)
fi

if [ ${#files[@]} -eq 0 ]; then
    echo "no files to scan"
    exit 0
fi

hits=0
for pattern in "${patterns[@]}"; do
    while IFS= read -r match; do
        [ -z "$match" ] && continue
        echo "forbidden-word hit: pattern=/$pattern/ -> $match"
        hits=$((hits + 1))
    done < <(cd "$REPO_ROOT" && grep -niE -- "$pattern" "${files[@]}" 2>/dev/null || true)
done

if [ $hits -gt 0 ]; then
    echo ""
    echo "Forbidden-word scan failed with $hits hit(s)."
    echo "See .forbidden-words for the pattern list."
    exit 1
fi

echo "forbidden-word scan: 0 hits across ${#files[@]} file(s), ${#patterns[@]} pattern(s)"
