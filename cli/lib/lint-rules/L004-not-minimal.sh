#!/usr/bin/env bash
# L004 not-minimal (deep)
#
# Checks whether a defconfig is in the canonical minimal form that
# `make savedefconfig` produces. When a defconfig accumulates redundant
# assignments (values equal to Kconfig `default`) or stale comments,
# `savedefconfig` drops them. The defconfig still works, but it is no
# longer the canonical minimal form — diffs against future savedefconfig
# output will be misleading, and reviewers cannot easily tell which lines
# carry real intent.
#
# The rule performs a Kconfig roundtrip in a scratch directory:
#   1. cp <defconfig> <scratch>/.config
#   2. make -C <project_root> O=<scratch> olddefconfig   (resolve selects/depends)
#   3. make -C <project_root> O=<scratch> savedefconfig  (produce minimal form)
#   4. compare input vs <scratch>/defconfig
#
# If the two differ, the input is not minimal — emit one warn finding with
# line-delta counts.
#
# Gated behind --deep. Silently skipped unless KCONFORM_DEEP=1 is exported
# by the lint runner. See cli/lib/lint.sh for the gate logic.
#
# Scratch dir policy: all files under $PWD/.kconform-tmp/ (never /tmp). On
# exit the scratch is removed unless KCONFORM_KEEP_SCRATCH=1, or unless a
# make step failed — in which case the scratch is preserved so the user
# can read $scratch/make.log.

set -eu

defconfig="$1"
project_root="$2"
# platform="$3"   # reserved for future per-platform tweaks

if [ "${KCONFORM_DEEP:-0}" != "1" ]; then
    exit 0
fi

# Resolve defconfig to an absolute path before any cd happens.
case "$defconfig" in
    /*) ;;
    *) defconfig="$PWD/$defconfig" ;;
esac

scratch_base="$PWD/.kconform-tmp"
scratch="$scratch_base/l004-$$-$(date +%s)"
mkdir -p "$scratch"

cleanup() {
    if [ "${KCONFORM_KEEP_SCRATCH:-0}" = "1" ]; then
        return
    fi
    rm -rf "$scratch"
    # If scratch_base is now empty, remove it too (tidy cleanup).
    rmdir "$scratch_base" 2>/dev/null || true
}
trap cleanup EXIT

cp "$defconfig" "$scratch/.config"

log="$scratch/make.log"

if ! make -C "$project_root" O="$scratch" olddefconfig >"$log" 2>&1; then
    # Preserve scratch for user inspection of the make error.
    trap - EXIT
    printf '{"rule":"L004","severity":"info","symbol":"-","message":"skipped: make olddefconfig failed (see %s/make.log); defconfig could not be roundtripped","fix":"Run kconform lint --deep from a tree where make <board>_defconfig normally works. Ensure ARCH and any required toolchain env is set."}\n' "$scratch"
    exit 0
fi

if ! make -C "$project_root" O="$scratch" savedefconfig >>"$log" 2>&1; then
    trap - EXIT
    printf '{"rule":"L004","severity":"info","symbol":"-","message":"skipped: make savedefconfig failed (see %s/make.log)","fix":"Inspect the make log for details."}\n' "$scratch"
    exit 0
fi

if [ ! -f "$scratch/defconfig" ]; then
    trap - EXIT
    printf '{"rule":"L004","severity":"info","symbol":"-","message":"skipped: savedefconfig produced no output file (see %s/make.log)","fix":"Inspect the scratch dir and make log."}\n' "$scratch"
    exit 0
fi

if cmp -s "$defconfig" "$scratch/defconfig"; then
    exit 0
fi

# Defconfig differs from savedefconfig output — not minimal.
removed=$(diff "$defconfig" "$scratch/defconfig" | grep -c '^<' || true)
added=$(diff "$defconfig" "$scratch/defconfig" | grep -c '^>' || true)
removed="${removed:-0}"
added="${added:-0}"

printf '{"rule":"L004","severity":"warn","symbol":"-","message":"defconfig is not in minimal form: savedefconfig roundtrip removes %d line(s) and adds %d line(s)","fix":"Replace the defconfig with the savedefconfig output. Re-run with --deep --keep-scratch to inspect the produced file and the diff."}\n' "$removed" "$added"
