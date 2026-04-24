# Changelog

All notable changes to **kconform**. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.11] — 2026-04-24

### Added

- `kconform menuconfig [--platform=<n>] [--arch=<arch>]` — thin wrapper for `make menuconfig`, sets ARCH via the platform adapter and runs in the detected project root.
- `kconform minimize <defconfig> [--check|--yes] [--json]` — normalize a defconfig via savedefconfig roundtrip. Default `--check` mode is a dry-run suitable for CI (exit 1 if the defconfig is not minimal); `--yes` writes the canonical form back in place.

## [0.1.10] — 2026-04-24

### Added

- `kconform fragment diff <f1> <f2> [--json]` — directive-level comparison of two fragments. Reports `only_in_f1`, `only_in_f2`, and `differs` symbol lists. Exit 0 if equivalent, 1 if they differ.
- `kconform fragment new --from-diff <cfg1> <cfg2> <out>` — generate a fragment that captures the delta from `cfg1` to `cfg2`. Only emits directives present in `cfg2` that are missing or differ in `cfg1`; "only in cfg1" symbols are intentionally *not* materialized as `# CONFIG_X is not set` because absence from `cfg2` cannot be distinguished from savedefconfig's default-minimization.

## [0.1.9] — 2026-04-24

### Added

- `kconform fragment apply <frag> <base> [--out=<path>] [--json]` — merge a fragment onto a base defconfig. Runs `make olddefconfig` + `make savedefconfig` in a scratch directory (under `$PWD/.kconform-tmp/`) and emits the resulting minimal defconfig. Reports added / removed / changed symbols at the `.config` level.

## [0.1.8] — 2026-04-24

### Fixed

- `fragment new` template: placeholder changed from `CONFIG_X` to `CONFIG_<NAME>` so the generated file passes `fragment lint` cleanly. Also added a regression test (`tests/cases/fragment/lint-generated-template/`) that lints a snapshot of the current template output.

## [0.1.7] — 2026-04-23

### Added

- `kconform fragment new <name>` — write a commented empty fragment template to `<name>.cfg`. The template documents every valid fragment line shape and warns against pseudo-disable (`# CONFIG_X=y`).
- `kconform fragment lint <frag> [--json]` — validate fragment syntax. Classifies findings as `pseudo-disable`, `bad-symbol`, or `unrecognized`. Exits 0 / 1 / 2 on clean / invalid / file error.

## [0.1.6] — 2026-04-23

### Added

- `kconform symbol <CONFIG_X|X> [--json]` — look up a Kconfig symbol. Prints `defined-at file:line`, type (bool/string/int/hex/tristate), prompt, default(s), depends-on, selects, implies, and the first help line. Supports symbols declared with either `config` or `menuconfig` and reports multi-site declarations separately.

## [0.1.5] — 2026-04-23

### Fixed

- `kconform verify` — two bugs that only fired on the real `make` path (fixture tests cover the byte-identical short-circuit only):
  - `keep_scratch: unbound variable`: EXIT trap referenced `cmd_verify` locals after the function returned. Trap body now interpolates concrete paths at setup time.
  - `comm: file is not in sorted order`: `comm` was called without `LC_ALL=C` while inputs were sorted under `LC_ALL=C sort`. Added `LC_ALL=C` to both `comm` invocations.

## [0.1.4] — 2026-04-23

### Added

- `kconform verify <before> <after> [--json] [--keep-scratch]` — prove or disprove that two defconfigs produce semantically equivalent `.config` after `make olddefconfig` normalization.
  - **Note**: this release has trap-scope and locale bugs on the make path; use **v0.1.5**.

## [0.1.3] — 2026-04-23

### Added

- Lint rule **L004 `not-minimal`** (deep, severity = warn): detects when a defconfig differs from its savedefconfig roundtrip output.
- `--deep` flag on `kconform lint` — enables rules that shell out to `make` (currently L004+).
- `--keep-scratch` flag — preserve debug scratch directory.
- Convention: scratch directories live under `$PWD/.kconform-tmp/` (never `/tmp`). Auto-cleaned on exit.
- `.kconform-tmp/` added to the repo's `.gitignore` so contributors invoking kconform from the source checkout don't see it in `git status`.

## [0.1.2] — 2026-04-22

### Added

- Lint rule **L002 `non-standard-comment`** (fast, severity = warn): flags `# CONFIG_X=y` pseudo-disable lines. The canonical disable form is `# CONFIG_X is not set` (no `=` sign).

### Fixed

- Documented constraint in `cli/lib/lint.sh` that lint rule authors must not use double quotes in `message` / `fix` JSON strings, because the flat-JSON extractor does not handle escaped quotes. The `--json` output is unaffected.

## [0.1.1] — 2026-04-22

### Fixed

- `kconform detect` — switched from Makefile content grep to structural markers. The previous heuristic required the project's Makefile to mention `u-boot` in its first 40 lines; upstream U-Boot's Makefile inherits its header from the Linux kernel and has no such marker, so detection failed on every real tree. The new heuristic requires four structural signals at the project root: `configs/`, `Kconfig`, `Makefile`, and `cmd/`. Fixture Makefile rewritten without the "U-Boot" marker to lock in the regression.

## [0.1.0] — 2026-04-22

### Added

- Walking skeleton: `kconform detect` + `kconform lint` wired end to end for U-Boot.
- Lint rule **L001 `ghost-symbol`** (fast, severity = error): detects `CONFIG_X=y` lines whose symbol has no `config` or `menuconfig` definition anywhere in the Kconfig tree. The grep pattern covers both keywords — the real-world trigger for this project was a heuristic that matched only `config` and silently missed `menuconfig` declarations.
- U-Boot platform adapter (`cli/platforms/uboot.sh`).
- Fixture-based golden-file test runner at `tests/run-tests.sh`.
- GitHub Actions CI: shellcheck, test suite, and forbidden-words scan.
- `.forbidden-words` pattern list + `scripts/check-forbidden-words.sh` scanner.
- Apache-2.0 license.

[Unreleased]: https://github.com/<your-fork>/kconform/compare/v0.1.11...HEAD
[0.1.11]: https://github.com/<your-fork>/kconform/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/<your-fork>/kconform/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/<your-fork>/kconform/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/<your-fork>/kconform/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/<your-fork>/kconform/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/<your-fork>/kconform/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/<your-fork>/kconform/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/<your-fork>/kconform/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/<your-fork>/kconform/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/<your-fork>/kconform/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/<your-fork>/kconform/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/<your-fork>/kconform/releases/tag/v0.1.0
