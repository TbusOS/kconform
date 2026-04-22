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

# U-Boot signature: Kconfig at root + configs/ directory + Makefile mentioning
# U-Boot in its header comment. This distinguishes from the Linux kernel
# (which keeps defconfigs under arch/<arch>/configs/).
_kconform_match_uboot() {
    local d="$1"
    [ -d "$d/configs" ] || return 1
    [ -f "$d/Kconfig" ] || return 1
    [ -f "$d/Makefile" ] || return 1
    # Header comment style: "# SPDX... U-Boot" or "VERSION = ..." near a
    # U-Boot mention. Scan the first 40 lines to keep this cheap.
    head -n 40 "$d/Makefile" 2>/dev/null | grep -qiE 'u[-_]?boot' || return 1
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
