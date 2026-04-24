# kconform

**A polyglot toolkit for `Kconfig`-style configuration systems across embedded and Linux projects.**

kconform wraps what your framework already ships (`make menuconfig`, `merge_config.sh`, `savedefconfig`, `scripts/config`, `scripts/diffconfig.sh`, …) and adds the missing pieces:

- **Lint** — detect ghost symbols, pseudo-disable comments, non-minimal defconfigs.
- **Verify** — prove two defconfigs produce equivalent `.config`.
- **Symbol lookup** — inspect where `CONFIG_X` is defined, its default, depends, selects.
- **Minimize** — normalize a defconfig via savedefconfig roundtrip.
- **Fragments** — generate, validate, apply, diff `.cfg` fragments; extract deltas from two configs.
- **menuconfig wrapper** — set ARCH correctly and drop into the native UI.

## Status

**v0.1.13 · U-Boot feature-complete · first public release**. Every verb described in this README is implemented and validated end-to-end against [upstream U-Boot](https://github.com/u-boot/u-boot). Support for the Linux kernel, Buildroot, OpenWrt, and Android is planned (see [Supported platforms](#supported-platforms)).

See [DESIGN.md](./DESIGN.md) for the full design, roadmap, and extension model.

## Install

```bash
git clone https://github.com/TbusOS/kconform.git
ln -sf "$PWD/kconform/cli/kconform" ~/.local/bin/kconform   # or any dir on PATH
kconform --version
```

Dependencies: `bash` 3.2+, plus `make`, `sed`, `grep`, `find`, `awk` (standard POSIX + GNU extensions that come with every Linux distro). No pip / npm / Go.

## Quick start

Open a U-Boot tree and run:

```bash
$ cd /path/to/your/u-boot

# Detect the platform
$ kconform detect
platform:     uboot
project root: /path/to/your/u-boot
defconfigs:   /path/to/your/u-boot/configs

# Fast lint: ghost symbols + pseudo-disables
$ kconform lint configs/qemu_arm64_defconfig
kconform lint: configs/qemu_arm64_defconfig
  clean — 2 rule(s) ran, 0 findings

# Deep lint: also runs savedefconfig roundtrip (needs make)
$ kconform lint configs/qemu_arm64_defconfig --deep
kconform lint: configs/qemu_arm64_defconfig
  warn  [L004] -: defconfig is not in minimal form: savedefconfig roundtrip removes 1 line(s) and adds 1 line(s)
         fix: Replace the defconfig with the savedefconfig output. Re-run with --deep --keep-scratch to inspect.
  1 finding(s), 3 rule(s) ran

# Look up a symbol
$ kconform symbol CONFIG_AHCI
CONFIG_AHCI
  defined at: /path/to/your/u-boot/drivers/ata/Kconfig:1
  type:       bool
  prompt:     "Support SATA controllers with driver model"
  depends on: DM
  selects:    BLK
  help:       This enables a uclass for disk controllers in U-Boot. Various driver

# Prove two defconfigs are semantically equivalent
$ kconform verify configs/board_v1_defconfig configs/board_v2_defconfig

# Normalize a defconfig to savedefconfig canonical form (in place)
$ kconform minimize configs/my_board_defconfig --check   # dry-run
$ kconform minimize configs/my_board_defconfig --yes     # write back

# Generate a fragment template, validate it, apply it
$ kconform fragment new security-hardening.cfg          # writes template
$ vim security-hardening.cfg                            # author edits it
$ kconform fragment lint security-hardening.cfg
$ kconform fragment apply security-hardening.cfg configs/qemu_arm64_defconfig \
    --out=configs/qemu_arm64_secure_defconfig

# Extract a fragment from the delta between two defconfigs
$ kconform fragment new --from-diff configs/board_a_defconfig configs/board_b_defconfig delta.cfg

# Compare two fragments
$ kconform fragment diff fragment-a.cfg fragment-b.cfg

# Drop into the native menuconfig UI with the right ARCH
$ kconform menuconfig
```

Every verb accepts `--help`, `--json` (where applicable), and `--platform=<name>` to override autodetect.

## Verbs

| Verb | Purpose |
|---|---|
| `detect` | Identify the platform in the current tree; print root and defconfig dir |
| `lint <defconfig> [--deep]` | Run fast rules (L001/L002) or fast + deep rules (L004) |
| `verify <before> <after>` | Prove two defconfigs produce equivalent `.config` |
| `symbol <CONFIG_X>` | Show where a Kconfig symbol is defined + its attributes |
| `minimize <defconfig> [--yes]` | Normalize a defconfig via savedefconfig roundtrip |
| `menuconfig` | Thin wrapper over `make menuconfig` with correct ARCH |
| `fragment new <name> [--from-diff <a> <b>]` | Write a template or extract one from a diff |
| `fragment lint <frag>` | Validate fragment syntax |
| `fragment apply <frag> <base>` | Merge fragment onto base; produce minimal defconfig |
| `fragment diff <f1> <f2>` | Compare two fragments at the directive level |

Exit codes follow a consistent scheme:
- `0` — clean / equivalent / applied
- `1` — finding present / differences found
- `2` — tool error (file missing, platform not detected, make failed, …)
- `130` — user interrupt (SIGINT)

## Lint rules

| ID | Severity | Tier | What it catches |
|---|---|---|---|
| L001 | error | fast | Ghost symbols — `CONFIG_X=y` with no `config`/`menuconfig` definition anywhere in the Kconfig tree |
| L002 | warn | fast | Pseudo-disable — `# CONFIG_X=y` that looks like a disable directive but is a plain comment; the canonical disable is `# CONFIG_X is not set` |
| L004 | warn | deep (`--deep`) | Not-minimal — defconfig differs from the `savedefconfig` roundtrip output |

Fast rules run as grep/awk over the Kconfig tree (milliseconds). Deep rules shell out to `make olddefconfig` + `make savedefconfig` in a scratch directory and need a working Kconfig toolchain in the target tree. Deep rules are gated behind `--deep`.

Scratch directory: `$PWD/.kconform-tmp/` (never `/tmp`). Auto-cleaned on exit unless you pass `--keep-scratch`. Add `.kconform-tmp/` to your project's `.gitignore` if you want to keep `git status` clean.

## Supported platforms

| Platform | Status |
|---|---|
| **U-Boot** | **feature-complete** (detect, lint, verify, symbol, minimize, menuconfig, fragment×4) |
| Linux kernel | planned — uboot adapter pattern is 90% reusable |
| Buildroot | planned |
| OpenWrt | planned |
| Android (Soong+Make) | planned (limited — Android does not use Kconfig) |

Adapters are small (~50 lines each). The [adapter contract](./DESIGN.md#42-adapter-contract) is stable.

## Development

```bash
./tests/run-tests.sh                       # golden-file test suite
./tests/run-tests.sh lint/ghost-symbol     # filter by substring
./scripts/check-forbidden-words.sh         # scan committed files for forbidden patterns
shellcheck cli/kconform cli/lib/*.sh cli/lib/lint-rules/*.sh cli/platforms/*.sh \
           tests/run-tests.sh scripts/check-forbidden-words.sh
```

GitHub Actions runs all three on every PR.

Test layout is golden-file style: each case lives under `tests/cases/<verb>/<name>/` with a `cmd` file, `expected-exit`, and optional stdout/stderr substring assertions.

See [DESIGN.md](./DESIGN.md) for the architecture and [CHANGELOG.md](./CHANGELOG.md) for version history.

## Contributing

- PRs welcome. Keep `shellcheck` clean, add a test case for any behavior change, and write user-friendly error messages.
- CI enforces `shellcheck`, the test suite, and a forbidden-words scan (`.forbidden-words`).
- DCO sign-off appreciated but not yet strictly enforced.

## License

Apache-2.0. See [LICENSE](./LICENSE).

---

This repo is **open-source-by-design**: no vendor names, no internal paths, no proprietary data. Organizations with proprietary rules, fragments, or adapter extensions should keep them in a private companion repo per the [DESIGN §9](./DESIGN.md#9-internal-companion-repo-pattern) pattern.
