# cli/lib/detect.sh — platform autodetect and the `detect` verb.
#
# Sourced by cli/kconform. Expects KCONFORM_ROOT and KCONFORM_CLI_DIR in env.
#
# Public functions:
#   kconform_find_project_root [<start_dir>]   -> prints project root, or returns 1
#   kconform_detect_platform    [<root_dir>]   -> prints platform name, or returns 1
#   cmd_detect [--platform=<name>]            -> implements the `detect` verb

# Walks upward from <start_dir> looking for a directory that matches any known
# platform signature. Prints the matched directory, returns 1 if none found.
kconform_find_project_root() {
    local start="${1:-$PWD}"
    local dir
    dir="$(cd "$start" && pwd)"
    while :; do
        if _kconform_match_uboot "$dir"; then
            echo "$dir"
            return 0
        fi
        # Future platforms: linux, buildroot, openwrt, android.
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

# Given a project root, prints the platform name.
kconform_detect_platform() {
    local root="${1:-$PWD}"
    if _kconform_match_uboot "$root"; then
        echo "uboot"
        return 0
    fi
    return 1
}

# U-Boot signature: four structural markers that together uniquely identify a
# U-Boot source tree among the platforms kconform supports.
#
#   configs/     U-Boot keeps defconfigs at the project root (the Linux kernel
#                keeps them under arch/<arch>/configs/ instead).
#   Kconfig      Both U-Boot and the kernel have this; common to Kconfig-family.
#   Makefile     Both U-Boot and the kernel have this; common.
#   cmd/         U-Boot-specific. Holds the command implementations (bootm,
#                mmc, part, ...). The Linux kernel has no cmd/ directory, nor
#                do Buildroot/OpenWrt at their roots. This is what pins the
#                signature to U-Boot.
#
# Deliberately does NOT grep the Makefile's content. Upstream U-Boot's Makefile
# inherits its header from the Linux kernel and does not necessarily mention
# "u-boot" in its first dozens of lines.
_kconform_match_uboot() {
    local d="$1"
    [ -d "$d/configs" ] || return 1
    [ -f "$d/Kconfig" ] || return 1
    [ -f "$d/Makefile" ] || return 1
    [ -d "$d/cmd" ] || return 1
    return 0
}

cmd_detect() {
    local platform_override=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --platform=*) platform_override="${1#--platform=}"; shift ;;
            -h|--help)
                cat <<'EOF'
kconform detect [--platform=<name>]

Detect the configuration platform in the current working directory (or walk up
until one is found). Prints:
  platform:     <name>
  project root: <absolute path>
  defconfigs:   <absolute path>

Exit codes:
  0  detected
  2  no supported platform found
EOF
                return 0 ;;
            *) echo "kconform detect: unexpected arg '$1'" >&2; return 2 ;;
        esac
    done

    local root platform
    if [ -n "$platform_override" ]; then
        platform="$platform_override"
        root="$PWD"
    else
        if ! root="$(kconform_find_project_root "$PWD")"; then
            echo "kconform detect: no supported platform found starting at $PWD" >&2
            echo "  Supported (so far): uboot. Run from inside a U-Boot source tree." >&2
            return 2
        fi
        platform="$(kconform_detect_platform "$root")"
    fi

    local adapter="$KCONFORM_CLI_DIR/platforms/$platform.sh"
    if [ ! -f "$adapter" ]; then
        echo "kconform detect: no adapter for platform '$platform' at $adapter" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$adapter"

    printf 'platform:     %s\n' "$platform"
    printf 'project root: %s\n' "$root"
    printf 'defconfigs:   %s\n' "$(kconform_defconfig_dir "$root")"
}
