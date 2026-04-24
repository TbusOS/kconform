# cli/lib/wrapper.sh — thin wrappers over the framework's native make targets.
#
# Sourced by cli/kconform. Exports two verbs:
#
#   kconform menuconfig         — run `make menuconfig` in the detected
#                                 project root with the platform adapter's
#                                 default ARCH (unless --arch overrides).
#   kconform minimize <def>     — normalize a defconfig via
#                                 `make olddefconfig` + `make savedefconfig`.
#                                 Dry-run by default (reports what would
#                                 change); --yes writes the result back in
#                                 place.

cmd_menuconfig() {
    local platform_override=""
    local arch_override=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --platform=*) platform_override="${1#--platform=}"; shift ;;
            --arch=*) arch_override="${1#--arch=}"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform menuconfig [--platform=<name>] [--arch=<arch>]

Run `make menuconfig` in the detected project root with the platform
adapter's default ARCH. Pass --arch=<arch> to override.

This is a convenience wrapper — all it does is find the project root,
set ARCH, and shell out. Identical to:

  cd <project_root> && ARCH=<arch> make menuconfig

Exit code is `make`'s. 130 if the user aborts with Ctrl-C.
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform menuconfig: unknown flag '$1'" >&2; return 2 ;;
            *) echo "kconform menuconfig: unexpected arg '$1'" >&2; return 2 ;;
        esac
    done

    local project_root platform
    if ! project_root="$(kconform_find_project_root "$PWD")"; then
        echo "kconform menuconfig: no supported platform detected at $PWD" >&2
        return 2
    fi
    if [ -n "$platform_override" ]; then
        platform="$platform_override"
    else
        platform="$(kconform_detect_platform "$project_root")"
    fi
    local adapter="$KCONFORM_CLI_DIR/platforms/$platform.sh"
    if [ ! -f "$adapter" ]; then
        echo "kconform menuconfig: no adapter for platform '$platform'" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$adapter"

    # Let the adapter set its defaults first, then apply --arch override.
    kconform_env
    if [ -n "$arch_override" ]; then
        ARCH="$arch_override"
        export ARCH
    fi

    # shellcheck disable=SC2153
    echo "kconform menuconfig: ARCH=$ARCH project=$project_root" >&2
    make -C "$project_root" menuconfig
}

cmd_minimize() {
    local defconfig=""
    local yes="0"
    local mode="text"
    local platform_override=""
    local keep_scratch="0"

    while [ $# -gt 0 ]; do
        case "$1" in
            --yes) yes="1"; shift ;;
            --check) yes="0"; shift ;;
            --json) mode="json"; shift ;;
            --platform=*) platform_override="${1#--platform=}"; shift ;;
            --keep-scratch) keep_scratch="1"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform minimize <defconfig> [--yes|--check] [--platform=<name>] [--keep-scratch] [--json]

Normalize <defconfig> by running `make olddefconfig` + `make savedefconfig`
in a scratch directory. Two modes:

  --check (default):   dry-run. Report whether <defconfig> is already
                       minimal. Exit 0 if clean, 1 if out of form, 2 on
                       tool error. Never writes.
  --yes:               write the minimized result back to <defconfig>.
                       Exit 0 always on success (whether or not anything
                       changed).

Scratch dir: $PWD/.kconform-tmp/minimize-<pid>-<ts>/, cleaned on exit
unless --keep-scratch or make fails.

This is the `savedefconfig roundtrip` workflow in one command — useful
before committing a hand-edited defconfig.
EOF
                return 0 ;;
            --) shift; break ;;
            -*) echo "kconform minimize: unknown flag '$1'" >&2; return 2 ;;
            *)
                if [ -z "$defconfig" ]; then defconfig="$1"
                else echo "kconform minimize: unexpected extra arg '$1'" >&2; return 2
                fi; shift ;;
        esac
    done

    if [ -z "$defconfig" ]; then
        echo "kconform minimize: missing <defconfig> argument" >&2
        return 2
    fi
    if [ ! -f "$defconfig" ]; then
        echo "kconform minimize: '$defconfig': no such file" >&2
        return 2
    fi

    defconfig="$(cd "$(dirname "$defconfig")" && pwd)/$(basename "$defconfig")"

    local project_root platform
    local defconfig_dir
    defconfig_dir="$(dirname "$defconfig")"
    if ! project_root="$(kconform_find_project_root "$defconfig_dir")"; then
        echo "kconform minimize: could not detect project root near '$defconfig'" >&2
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

    local scratch_base="$PWD/.kconform-tmp"
    local scratch="$scratch_base/minimize-$$-$(date +%s)"
    mkdir -p "$scratch"
    # shellcheck disable=SC2064
    if [ "$keep_scratch" = "1" ]; then
        trap "printf 'kconform minimize: scratch preserved at %s\\n' '$scratch' >&2" EXIT
    else
        trap "rm -rf '$scratch'; rmdir '$scratch_base' 2>/dev/null || true" EXIT
    fi

    cp "$defconfig" "$scratch/.config"
    if ! make -C "$project_root" O="$scratch" olddefconfig \
           >"$scratch/make.log" 2>&1; then
        trap - EXIT
        echo "kconform minimize: make olddefconfig failed" >&2
        echo "  see $scratch/make.log" >&2
        return 2
    fi
    if ! make -C "$project_root" O="$scratch" savedefconfig \
           >>"$scratch/make.log" 2>&1; then
        trap - EXIT
        echo "kconform minimize: make savedefconfig failed" >&2
        echo "  see $scratch/make.log" >&2
        return 2
    fi

    local already_minimal=0
    if cmp -s "$defconfig" "$scratch/defconfig"; then
        already_minimal=1
    fi

    local removed=0
    local added=0
    if [ $already_minimal -eq 0 ]; then
        removed=$(diff "$defconfig" "$scratch/defconfig" | grep -c '^<' || true)
        added=$(diff "$defconfig" "$scratch/defconfig" | grep -c '^>' || true)
    fi
    removed="${removed:-0}"
    added="${added:-0}"

    if [ $already_minimal -eq 1 ]; then
        if [ "$mode" = "json" ]; then
            printf '{"file":"%s","already_minimal":true,"changed":false,"written":false}\n' \
                "$(_kconform_fragment_json_escape "$defconfig")"
        else
            printf 'kconform minimize: %s is already minimal\n' "$defconfig"
        fi
        return 0
    fi

    # Not minimal.
    if [ "$yes" = "1" ]; then
        cp "$scratch/defconfig" "$defconfig"
        if [ "$mode" = "json" ]; then
            printf '{"file":"%s","already_minimal":false,"changed":true,"written":true,"lines_removed":%s,"lines_added":%s}\n' \
                "$(_kconform_fragment_json_escape "$defconfig")" "$removed" "$added"
        else
            printf 'kconform minimize: rewrote %s (removed %s, added %s line(s))\n' \
                "$defconfig" "$removed" "$added"
        fi
        return 0
    else
        # dry-run
        if [ "$mode" = "json" ]; then
            printf '{"file":"%s","already_minimal":false,"changed":false,"written":false,"lines_removed":%s,"lines_added":%s}\n' \
                "$(_kconform_fragment_json_escape "$defconfig")" "$removed" "$added"
        else
            printf 'kconform minimize: %s is NOT minimal\n' "$defconfig"
            printf '  savedefconfig roundtrip would remove %s line(s) and add %s line(s)\n' "$removed" "$added"
            printf '  re-run with --yes to rewrite in place\n'
        fi
        return 1
    fi
}
