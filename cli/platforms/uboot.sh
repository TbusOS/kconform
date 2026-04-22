# cli/platforms/uboot.sh — U-Boot adapter.
#
# Implements the 5-function adapter contract (see DESIGN §4.2). U-Boot borrows
# the Linux kernel Kconfig machinery verbatim, so most wrappers are one-liners
# over `make`.

# 1. Detection. Re-exports _kconform_match_uboot from detect.sh so external
#    callers don't need to know the private helper name.
kconform_detect() {
    _kconform_match_uboot "${1:-$PWD}"
}

# 2. Environment. U-Boot usually expects ARCH and CROSS_COMPILE for any
#    board-level target. For Phase 0 we only ensure ARCH has a value — the
#    caller can override.
kconform_env() {
    : "${ARCH:=arm}"
    export ARCH
    if [ -n "${CROSS_COMPILE:-}" ]; then
        export CROSS_COMPILE
    fi
}

# 3. Native make wrappers.
kconform_make_defconfig() {
    local board="$1"
    kconform_env
    make "${board}_defconfig"
}

kconform_make_menuconfig() {
    kconform_env
    make menuconfig
}

kconform_make_olddefconfig() {
    kconform_env
    make olddefconfig
}

kconform_make_savedefconfig() {
    kconform_env
    make savedefconfig
}

# 4. Tool paths.
kconform_merge_config_script_path() {
    local root="${1:-$PWD}"
    echo "$root/scripts/kconfig/merge_config.sh"
}

# 5. Location conventions.
kconform_defconfig_dir() {
    local root="${1:-$PWD}"
    echo "$root/configs"
}
