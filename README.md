# kconform

**A polyglot toolkit for `Kconfig`-style configuration systems across embedded and Linux projects.**

Wraps what your framework already ships (`make menuconfig`, `merge_config.sh`, `savedefconfig`, `scripts/config`, `scripts/diffconfig.sh`, …) and adds what they don't:

- **Lint**: detect ghost symbols, non-standard comments, non-minimal defconfigs.
- **Verify**: prove two defconfigs produce byte-identical `.config`.
- **Fragments**: generate, apply, validate `.cfg` fragments with a shared grammar.

Two tiers, same surface:
- **Plain CLI** — works in any shell, scriptable, CI-friendly.
- **AI skill** — drop `skills/kconform/` into your Claude Code / agent workspace for guided use (coming in Phase 1).

## Status

**v0.1.0-dev · walking skeleton**. U-Boot detection + ghost-symbol lint (L001) work end-to-end. Full roadmap lives in [DESIGN.md §7](./DESIGN.md#7-phased-roadmap).

## Quick start

```bash
# Detect the platform in your current tree.
cd /path/to/your/u-boot
/path/to/kconform/cli/kconform detect
# platform:     uboot
# project root: /path/to/your/u-boot
# defconfigs:   /path/to/your/u-boot/configs

# Lint a defconfig for ghost symbols.
kconform lint configs/my_board_defconfig
# kconform lint: configs/my_board_defconfig
#   error [L001] CONFIG_SOMETHING_UNDEFINED: symbol has no config/menuconfig definition in the Kconfig tree
#          fix: Define the symbol in a Kconfig file or remove the line from the defconfig.
#   1 finding(s), 1 rule(s) ran

# Machine-readable output for CI.
kconform lint configs/my_board_defconfig --json
```

Exit codes: `0` clean, `1` lint error, `2` tool error.

## Install

No packages yet. For now:

```bash
git clone https://github.com/<your-fork>/kconform.git
cd kconform
ln -s "$PWD/cli/kconform" ~/.local/bin/kconform   # or any dir on PATH
```

Requires `bash` (3.2+), `sed`, `grep`, `find`, `awk`. No pip/npm dependencies.

## Supported platforms

| Platform | Phase 0 | Phase 1 | Phase 2+ |
|---|:-:|:-:|:-:|
| U-Boot | detect + lint L001 | +L002/L003/L004, verify, symbol | fragments, menuconfig wrapper |
| Linux kernel |  | detect + lint + verify | fragments |
| Buildroot |  |  | Phase 3 |
| OpenWrt |  |  | Phase 3 |
| Android (Soong+Make) |  |  | Phase 3 (limited) |

## Why this exists

See [DESIGN §1](./DESIGN.md#1-problem-statement). Short version: every Kconfig project has its own conventions and helper scripts; engineers (and AI agents) keep re-deriving the rules from scratch and keep making the same five mistakes. kconform codifies those rules as runnable checks with self-explanatory output.

## Running the tests

```bash
./tests/run-tests.sh                     # all cases
./tests/run-tests.sh lint/ghost-symbol   # filter by substring
```

Test layout is golden-file style; each case lives under `tests/cases/<verb>/<name>/` with a `cmd` file, expected exit code, and optional stdout/stderr substring assertions.

## Contributing

- PRs welcome. Please keep `shellcheck` clean and add a test case for any behavior change.
- CI runs `shellcheck`, the test suite, and a forbidden-words scan (see `.forbidden-words`).
- DCO sign-off appreciated but not yet enforced.

## License

Apache-2.0. See [LICENSE](./LICENSE).

---

This repo is **open-source-by-design**: no vendor names, no internal paths, no proprietary data. Organizations that need to layer vendor-specific adapters or fragments on top should follow the internal companion repo pattern in [DESIGN §9](./DESIGN.md#9-internal-companion-repo-pattern).
