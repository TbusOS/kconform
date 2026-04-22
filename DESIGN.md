# kconform · Design Document

> Status: **Draft v0.1** · 2026-04-22
> Audience: Another Claude Code CLI instance (implementer) + human collaborators
> This document is self-contained. Read top to bottom. Non-goals are as important as goals.

---

## 0. TL;DR (read this first)

**kconform** is a polyglot toolkit for working with `Kconfig`-style configuration systems across embedded/Linux projects. It wraps the native tools each framework already ships (`make menuconfig`, `merge_config.sh`, `savedefconfig`, `scripts/config`, `scripts/diffconfig.sh`, ...) and adds three things those tools don't offer in a unified form:

1. **Linting** — detect ghost symbols, non-standard comments, non-minimal defconfigs.
2. **Equivalence verification** — prove two defconfigs produce byte-identical `.config`.
3. **Fragment tooling** — generate, apply, validate fragment `.cfg` files with a shared syntax rule across frameworks.

Two user tiers:
- **Plain CLI** (`kconform <verb> ...`) — colleagues without Claude Code CLI can drive it from bash/zsh, suitable for CI and manual work.
- **AI skill** (`skills/kconform/`) — wraps CLI with structured prompts, judgment guidelines, and decision trees so AI agents (Claude Code, Cursor, Gemini CLI, etc.) can use it effectively.

**Supported platforms**: Linux kernel · U-Boot · Buildroot · OpenWrt · Android Soong/Make. Each gets a platform-specific adapter; the CLI surface stays uniform.

**Distribution**: MIT or Apache-2.0 open-source repo. No vendor names, no internal paths, no proprietary data. An optional **internal companion repo** (separate, never pushed public) holds vendor-specific templates and integrations.

---

## 1. Problem statement

### 1.1 The mess today

Across Linux kernel, U-Boot, Buildroot, OpenWrt, yocto, ... every project that uses `Kconfig` has its own set of conventions and scripts. Engineers learn one (usually kernel), then forget that U-Boot's `scripts/kconfig/merge_config.sh` is slightly different, that OpenWrt uses `scripts/diffconfig.sh`, that Buildroot has `BR2_EXTERNAL` fragments. When they move between projects — or onboard a new team member — the same mistakes recur:

1. Edit `configs/*_defconfig` directly with `vim`, skip `savedefconfig` roundtrip → defconfig becomes non-minimal, accumulates redundant `=y` lines that match `default`.
2. Write `# CONFIG_X=y` as a "disable marker" → Kconfig parser ignores this (it's a plain comment); only `# CONFIG_X is not set` is the canonical disable form.
3. Paste a `CONFIG_X=y` line whose symbol has no definition in the current Kconfig tree → Kconfig silently drops it at `.config` generation; feature never compiles in.
4. Miss a `select X` / `imply Y` chain when manually toggling → unexpected selections land in `.config`.
5. When reviewing a config change, diff `defconfig` instead of `.config` → cannot tell what business behavior actually changed vs cosmetic minimization.

### 1.2 Real-world trigger

In 2026-04-22, while porting a secure-boot signing flow between SDK versions, an engineer saw `make savedefconfig` emit a defconfig missing 5 `CONFIG_<VENDOR>_<FEATURE>=y` lines that the old defconfig had. The first hypothesis was "these symbols lost their Kconfig definitions during the SDK migration and features are silently disabled". Two rounds of debugging later, the actual cause turned out to be: (a) a grep pattern that only matched `^config` missed symbols declared as `menuconfig`; (b) `savedefconfig` correctly omitted those lines because their values matched `default`, which is its designed minimization behavior. No bug — just tools working correctly and humans misreading them.

That's the kind of 2-hour detour `kconform` is meant to prevent — **codify the framework's own rules into runnable lint checks, with clear explanatory output**, so that engineers (and AI agents) don't re-derive them from first principles each time.

### 1.3 Non-goals

kconform is **not**:

- A replacement for `make menuconfig` — it wraps it, doesn't reimplement the UI.
- A Kconfig parser — uses the framework's own parser via `make olddefconfig` / `merge_config.sh`.
- A build system — doesn't compile anything; never runs `make all` or similar.
- A generic config-file manager for non-Kconfig systems (JSON, TOML, env files, ...). Scope is exclusively Kconfig-family.
- Vendor-aware. The open repo carries zero vendor references. Vendor specifics live in the separate internal companion.

---

## 2. Design principles

1. **Thin wrappers over framework-native tools.** Never reimplement what `merge_config.sh` already does; shell out to it. If the framework updates its toolchain, kconform inherits the update.
2. **Two tiers, same surface.** Plain CLI and AI skill share the same commands and flags. AI skill is literally a `SKILL.md` + reference docs that *teach* the CLI — no separate code paths.
3. **Read-only by default, mutating with explicit flags.** `lint` / `verify` / `detect` / `diff` / `symbol` don't change files. Mutating actions (`minimize`, `apply`, `menuconfig`) require explicit verbs.
4. **Platform-aware but platform-abstract.** CLI verbs are uniform; platform detection happens internally. Users only pass `--platform=` when autodetect fails.
5. **Self-documenting output.** Every error prints the *why* and the *how to fix*, with a reference link to the corresponding doc page. No `Error: bad config` without next steps.
6. **Machine-readable output on demand.** `--json` / `--format=json` for every command. CI pipelines and AI agents can parse structured output rather than regex-scrape.
7. **Zero new dependencies preferred.** Bash + `awk` + `sed` + Python 3 (stdlib only) is the target. No npm, no pip packages, no Go. If something absolutely needs a dep, justify in the PR.

---

## 3. Scope: supported platforms

| # | Platform | Defconfig location | Native tools kconform wraps | Adapter file |
|---|---|---|---|---|
| 1 | **Linux kernel** | `arch/<arch>/configs/*_defconfig` | `make <b>_defconfig`, `make menuconfig`, `make savedefconfig`, `make olddefconfig`, `scripts/kconfig/merge_config.sh`, `scripts/config` (CLI to read/write `.config`), `scripts/kconfig/streamline_config.pl` | `cli/platforms/linux.sh` |
| 2 | **U-Boot** | `configs/*_defconfig` | Same as kernel (U-Boot borrows kernel's Kconfig scripts verbatim); one difference: default `ARCH=arm` for 32-bit SPL targets. | `cli/platforms/uboot.sh` |
| 3 | **Buildroot** | `configs/*_defconfig`, `BR2_EXTERNAL` fragments | `make <b>_defconfig`, `make menuconfig`, `make savedefconfig`, `support/kconfig/merge_config.sh`, `BR2_EXTERNAL=<path>` override | `cli/platforms/buildroot.sh` |
| 4 | **OpenWrt** | `.config` + target profile | `make menuconfig`, `scripts/diffconfig.sh`, `scripts/feeds` | `cli/platforms/openwrt.sh` |
| 5 | **Android (Soong+Make)** | `BoardConfig.mk`, `device.mk`, `system/core/rootdir/...`; no Kconfig | Makefile include-chain inspection; `lunch` / `envsetup.sh`; `m` targets | `cli/platforms/android.sh` (limited scope — linting only for now; Android doesn't use Kconfig so most commands are no-ops or platform-specific analogs) |

Additional platforms can be added by dropping a new adapter in `cli/platforms/` + registering in `cli/lib/detect.sh`. Contribution guide in `docs/CONTRIBUTING.md` explains the 5-function contract each adapter must implement.

---

## 4. Architecture

### 4.1 High-level diagram

```
                    User (human via CLI  OR  AI agent via skill)
                                     │
                                     ▼
                       ┌──────────────────────────┐
                       │    kconform CLI entry     │     cli/kconform
                       │  parse verb + flags      │
                       └──────────┬───────────────┘
                                  │
                                  ▼
                       ┌──────────────────────────┐
                       │    Platform detector     │     cli/lib/detect.sh
                       │  (scan CWD for markers)  │
                       └──────────┬───────────────┘
                                  │  dispatches to
                                  ▼
        ┌───────────┬───────────┬───────────┬───────────┬───────────┐
        │  linux    │  uboot    │ buildroot │  openwrt  │  android  │
        │  adapter  │  adapter  │  adapter  │  adapter  │  adapter  │
        └─────┬─────┴─────┬─────┴─────┬─────┴─────┬─────┴─────┬─────┘
              │           │           │           │           │
              └───────────┴─────┬─────┴───────────┴───────────┘
                                ▼
                   ┌────────────────────────────┐
                   │  Shared core libs          │     cli/lib/
                   │  - fragment parser         │
                   │  - lint rules              │
                   │  - equivalence verifier    │
                   │  - report formatter        │
                   └────────────────────────────┘
                                │
                                ▼
                   ┌────────────────────────────┐
                   │  Native framework tools    │
                   │  (make, merge_config.sh,   │
                   │   savedefconfig, ...)      │
                   └────────────────────────────┘
```

### 4.2 Adapter contract

Every adapter at `cli/platforms/<name>.sh` must export these 5 functions:

```bash
# 1. Detection: return 0 if CWD is this platform, non-0 otherwise.
kconform_detect() { ... }

# 2. Environment: export ARCH, CROSS_COMPILE, KBUILD_OUTPUT, etc.
kconform_env() { ... }

# 3. Native make wrappers.
kconform_make_defconfig "$board"       # make <board>_defconfig
kconform_make_menuconfig
kconform_make_olddefconfig
kconform_make_savedefconfig

# 4. Tool paths (different frameworks put tools in different places).
kconform_merge_config_script_path      # echo path to merge_config.sh

# 5. Location conventions.
kconform_defconfig_dir                 # echo where defconfigs live (configs/ or arch/$ARCH/configs/ or ...)
```

Adapters are small (50-150 lines each). The heavy lifting is in `cli/lib/`.

### 4.3 Shared library: lint rules

Lint rules are implemented in `cli/lib/lint.sh` as independent check functions. Each rule:

- Takes `<defconfig_path>` as arg
- Returns JSON lines: `{"rule": "L001", "severity": "error|warn|info", "symbol": "...", "message": "...", "fix": "..."}`
- Has a corresponding doc page at `docs/lint-rules/<id>.md` explaining why it exists

Initial rule set:

| ID | Rule | Severity | What it catches |
|---|---|---|---|
| L001 | `ghost-symbol` | error | A `CONFIG_X=y` line where `X` has no `config`/`menuconfig` definition anywhere in the Kconfig tree |
| L002 | `non-standard-comment` | warn | Lines like `# CONFIG_X=y` that look like disable markers but are plain comments |
| L003 | `redundant-default` | info | `CONFIG_X=<val>` where `<val>` equals Kconfig `default` (savedefconfig would drop it) |
| L004 | `not-minimal` | warn | `make savedefconfig` produces a different output → defconfig is not currently minimal |
| L005 | `depends-violation` | error | `CONFIG_X=y` but `X depends on Y` where `Y` is `n` in current config |
| L006 | `select-conflict` | warn | `# CONFIG_X is not set` but something else `select X` — result will be `y` regardless |
| L007 | `deprecated-symbol` | warn | Optional: symbol is in a Kconfig deprecation list (platform-specific) |

Rule L005 and L006 require running `make olddefconfig` against a scratch `.config` — more expensive, enabled only with `--deep` flag.

### 4.4 Shared library: equivalence verifier

`cli/lib/verify.sh`:

```
kconform verify <defconfig_before> <defconfig_after> [--report=<path>]
```

Algorithm:
1. Create two scratch working dirs `$(mktemp -d)`.
2. In each, run `cp <defconfig> $ws/<platform_default_defconfig_name>` + `make <platform_default_defconfig_target>`.
3. Compare the resulting `.config` files byte-for-byte.
4. Produce a diff report with each line annotated:
   - `[equivalent]` same value, possibly different formatting
   - `[semantic-change]` different effective value (true bug/intended change)
   - `[order-only]` line reordered, not changed

Exit code: 0 if no `[semantic-change]` lines (any number of `[equivalent]` and `[order-only]` is fine). 1 if any semantic change. 2 on tool error.

### 4.5 Shared library: fragment tooling

`cli/lib/fragment.sh` supports:

- `kconform fragment new <name> [--from-diff=<path>]` — generate a fragment template, or extract one from a `.config` diff
- `kconform fragment apply <frag> [<base>]` — merge a fragment into the current or specified base defconfig, run olddefconfig, run savedefconfig, report result
- `kconform fragment lint <frag>` — validate fragment syntax (4 line types: enable / disable-canonical / value-assignment / comment)
- `kconform fragment diff <frag1> <frag2>` — show how two fragments differ

### 4.6 CLI surface (complete spec)

```
kconform <verb> [<args>] [--flags]

Verbs:
  detect                          Detect platform; print platform name and defconfig locations
  env                             Print env (ARCH, CROSS_COMPILE, ...) for the detected platform

  lint <defconfig> [--deep]       Run lint rules; print report; exit 0 on clean, 1 on errors
  verify <before> <after>         Prove two defconfigs produce equivalent .config
  minimize <defconfig>            Replace defconfig with savedefconfig-produced minimal version (with confirmation)

  symbol <CONFIG_X>               Show where symbol is defined, default value, depends, select, imply; current value in .config
  ghost <defconfig>               List ghost symbols (shorthand for: lint <defconfig> --filter=L001)

  fragment new <name>             Create a new empty fragment file
  fragment new <name> --from-diff <cfg1> <cfg2>
                                  Extract fragment from .config diff
  fragment apply <frag> [<base>]  Apply fragment to base defconfig
  fragment lint <frag>            Validate fragment syntax

  menuconfig                      Run platform-native menuconfig with correct ARCH/CROSS_COMPILE
  savedefconfig                   Run platform-native savedefconfig

Global flags:
  --platform=<name>               Override platform autodetect
  --arch=<arch>                   Override autodetected ARCH
  --cross-compile=<prefix>        Override autodetected CROSS_COMPILE
  --json                          Output JSON instead of human text
  --verbose / -v                  Verbose output
  --quiet / -q                    Suppress info messages
  --help / -h                     Show help
  --version                       Show version
  --no-color                      Disable ANSI colors

Return codes:
  0  Success, no issues
  1  Lint errors / semantic change detected / fragment invalid
  2  Tool error (framework not detected, missing dependency, make failed, ...)
  130  User interrupted (SIGINT)
```

---

## 5. Repository structure

```
kconform/
├── README.md                            # Quick start (30-line hook + examples)
├── LICENSE                              # MIT or Apache-2.0 (decide before first commit)
├── DESIGN.md                            # This file
├── CHANGELOG.md                         # Keep a Changelog format
├── CONTRIBUTING.md                      # How to add a platform, write a lint rule, etc.
├── .github/
│   ├── workflows/
│   │   ├── test.yml                     # Run test suite on PR
│   │   └── lint.yml                     # Shellcheck, pyflakes
│   └── ISSUE_TEMPLATE/
│       ├── bug_report.md
│       └── feature_request.md
├── cli/
│   ├── kconform                          # Main entry point (bash dispatcher, <100 lines)
│   ├── platforms/
│   │   ├── linux.sh
│   │   ├── uboot.sh
│   │   ├── buildroot.sh
│   │   ├── openwrt.sh
│   │   └── android.sh
│   └── lib/
│       ├── detect.sh                    # Platform autodetect
│       ├── env.sh                       # Env var helpers
│       ├── fragment.sh                  # Fragment parse/generate/apply
│       ├── lint.sh                      # Lint rule runner
│       ├── lint-rules/
│       │   ├── L001-ghost-symbol.sh
│       │   ├── L002-non-standard-comment.sh
│       │   ├── L003-redundant-default.sh
│       │   ├── L004-not-minimal.sh
│       │   ├── L005-depends-violation.sh
│       │   └── L006-select-conflict.sh
│       ├── symbol.sh                    # Symbol inspection
│       └── verify.sh                    # Equivalence verifier
├── skills/
│   └── kconform/
│       ├── SKILL.md                     # Entry doc for AI agents
│       ├── TRIGGER                      # Keywords that activate this skill
│       └── references/
│           ├── workflow.md              # 3 scenarios (scripted / menuconfig / multi-repo)
│           ├── platforms.md             # Platform differences cheatsheet
│           ├── fragment-syntax.md       # Fragment file format
│           ├── troubleshooting.md       # Common errors + fixes
│           └── decision-tree.md         # "savedefconfig drops a symbol — what now?" and similar
├── docs/
│   ├── index.md                         # Doc home
│   ├── concepts/
│   │   ├── kconfig-basics.md
│   │   ├── defconfig-vs-dotconfig.md
│   │   ├── savedefconfig-minimization.md
│   │   ├── fragment-syntax.md
│   │   └── equivalence-proofs.md
│   ├── tutorials/
│   │   ├── linux-kernel.md
│   │   ├── uboot.md
│   │   ├── buildroot.md
│   │   └── openwrt.md
│   ├── reference/
│   │   ├── cli.md                       # Full CLI reference (generated from `--help`)
│   │   ├── adapters.md                  # Platform adapter contract
│   │   └── lint-rules.md                # All lint rules and their docs
│   └── lint-rules/                      # One page per rule
│       ├── L001.md
│       ├── L002.md
│       └── ...
├── examples/
│   ├── linux-kernel/
│   │   └── README.md                    # Example: apply a CVE-mitigation fragment
│   ├── uboot/
│   │   └── README.md                    # Example: secure-boot-style fragment
│   ├── buildroot/
│   │   └── README.md                    # Example: toggling a package family
│   └── fragments/
│       └── README.md                    # Fragment examples (no vendor names!)
└── tests/
    ├── fixtures/
    │   ├── linux/                       # Test Kconfig trees (tiny, self-contained)
    │   ├── uboot/
    │   └── ...
    ├── cases/
    │   ├── detect/
    │   ├── lint/
    │   ├── verify/
    │   └── fragment/
    └── run-tests.sh
```

**File-size budget**: 
- `cli/kconform` main entry: ~100 lines.
- Each adapter: ~150 lines (target; can go to 300 if needed).
- Each lint rule: ~50-100 lines.
- `cli/lib/*.sh` core: ~200 lines each.
- Total bash: ~3000-4000 lines.
- Test fixtures are small Kconfig trees (~20 symbols each), ~500 lines total.

---

## 6. AI skill layer

`skills/kconform/SKILL.md` is the entry doc for AI agents. It must:

1. **Open with a one-paragraph mission statement.** "kconform is a Kconfig toolkit. Use it when the user asks about defconfig, Kconfig, menuconfig, fragments, or platform config validation across Linux kernel / U-Boot / Buildroot / OpenWrt / Android."
2. **List trigger phrases.** `defconfig` / `Kconfig` / `menuconfig` / `savedefconfig` / `merge_config.sh` / `CONFIG_*` / "config fragment" / platform keywords.
3. **Show the CLI cheatsheet.** Not a full manual — just the 10 most common verbs with one-line explanations.
4. **Link to `references/*.md` for deep dives.**
5. **Provide a decision tree** for common ambiguous situations (like `decision-tree.md`).

`skills/kconform/references/`:

- `workflow.md` — the 3 scenarios from the u-boot HTML (scripted AI / interactive menuconfig / multi-repo commit flow). Generalized across platforms.
- `platforms.md` — platform-by-platform quirks (ARCH variable defaults, where defconfigs live, which native tool to prefer).
- `fragment-syntax.md` — the 4 line types, canonical disable syntax, string quoting.
- `troubleshooting.md` — top 20 errors and fixes. Every `kconform` CLI error message references a troubleshooting section.
- `decision-tree.md` — "savedefconfig dropped CONFIG_X, is it bug A or benign B?" style flowcharts.

**Key principle**: the AI skill should *never* re-explain what the CLI already does. It should explain *judgment calls* — when to pick `verify` vs `lint`, how to interpret ambiguous output, when to stop and ask the user.

---

## 7. Phased roadmap

### Phase 0 — scaffolding (1-2 days)

- Create repo structure, README, LICENSE, CHANGELOG stubs.
- Write `cli/kconform` entry + `cli/lib/detect.sh`.
- One platform adapter: `uboot.sh` (smallest, most useful for the porting engineer who triggered this).
- One lint rule: L001 `ghost-symbol`.
- One test fixture (toy U-Boot-like Kconfig tree).
- CI: shellcheck + basic test run.

**Definition of done**: `kconform detect` returns `uboot` in a U-Boot tree. `kconform lint configs/foo_defconfig` runs L001 and prints results.

### Phase 1 — lint + verify for 2 platforms (1 week)

- Add `linux.sh` adapter.
- Add lint rules L002, L003, L004.
- Implement `kconform verify <before> <after>`.
- Add `symbol` verb.
- Flesh out `docs/concepts/` and `docs/lint-rules/`.
- Write `skills/kconform/SKILL.md` v1.

**Definition of done**: run `kconform lint` + `kconform verify` in both a kernel tree and a U-Boot tree. AI can invoke the skill and produce lint reports.

### Phase 2 — fragment tooling + menuconfig wrapper (1 week)

- Implement `kconform fragment new/apply/lint/diff`.
- Implement `kconform menuconfig` wrapper (thin: sets ARCH/CROSS_COMPILE, runs native make).
- Lint rules L005, L006 (the `--deep` ones).
- Tests for all fragment operations.

### Phase 3 — 3 more platforms (1-2 weeks)

- Adapters: `buildroot.sh`, `openwrt.sh`, `android.sh` (limited).
- Platform-specific test fixtures.
- Tutorials: `docs/tutorials/buildroot.md`, `openwrt.md`.

### Phase 4 — polish + launch (1 week)

- `--json` output mode for all verbs.
- `kconform ghost` shorthand verb.
- Example repos (`examples/linux-kernel/`, `examples/uboot/`, ...).
- README polish, demo GIF/asciinema.
- First tagged release (`v0.1.0`).
- Write a launch post (explain the problem with a real example, show what kconform prevents).

### Post-launch

- Community adapters (yocto, petalinux, Zephyr, ...).
- `kconform migrate` — cross-version defconfig migration helper.
- VS Code extension (stretch goal).

---

## 8. Open-source hygiene

### 8.1 Sensitive-word filter (MUST enforce at PR review time)

Forbidden terms anywhere in the open repo (code, docs, commits, issues):

| Term category | Why forbidden |
|---|---|
| Any specific SoC vendor name or chip family identifier | Vendor-neutral open project |
| Any company name or domain of the originating org | Same |
| Any personal real names in examples or commit metadata | Use generic `alice`, `bob`, `engineer` in examples |
| Any internal filesystem paths (real `/home/<user>/...`, mount points, etc.) | Examples must use `/path/to/<thing>` placeholders |
| Any internal server IPs, hostnames, ports, credentials | Never |
| Proprietary SDK version identifiers | Replace with `<SDK_VERSION>` |

The project maintains an explicit, opt-in pattern list in `.forbidden-words` at the repo root. Contributors in organizations with additional restrictions (vendor brand names, product codenames, proprietary feature identifiers) extend the file locally via their internal companion repo (see §9).

**Implementation**: add a `.github/workflows/forbidden-words.yml` CI check that greps the diff for known forbidden patterns. Ship with a starter block list in `.forbidden-words` and let contributors extend.

Examples in `examples/` use generic symbols like `CONFIG_ACME_FOO` / `CONFIG_EXAMPLE_FEATURE_X`. Never `CONFIG_<REALVENDOR>_<REALFEATURE>`.

### 8.2 License

Recommend **Apache-2.0**: patent grant is useful for a tool that wraps framework APIs, and compatibility with kernel-ecosystem projects is broad.

Fallback: **MIT** if simplicity matters more than patent protection.

### 8.3 Contribution model

- GitHub-hosted.
- PR-based.
- DCO sign-off required (Signed-off-by:).
- Code of Conduct: Contributor Covenant v2.1.
- All PRs must pass CI (shellcheck + test suite + forbidden-words check).

---

## 9. Internal companion repo pattern

kconform is open-source. Many organizations have Kconfig workflows with proprietary specifics they can't push upstream (vendor SDKs, internal kernel forks, secure-boot signing flows, etc.). The intended pattern:

```
                        Public                               Private
┌─────────────────────────────────────┐         ┌──────────────────────────────┐
│   kconform  (open, on GitHub)        │         │  <org>-kconform-ext  (private)│
│                                     │         │                              │
│   cli/kconform   (generic dispatch)  │◄────────│  cli/ext/                    │
│   cli/platforms/linux.sh            │  uses   │    <vendor>-sdk.sh           │
│   cli/lib/*.sh                      │         │    (inherits linux adapter,  │
│   skills/kconform/                   │         │     adds vendor patch paths) │
│   docs/                             │         │                              │
│                                     │         │  fragments/                  │
│                                     │         │    <proprietary-feature>.cfg │
│                                     │         │                              │
│                                     │         │  skills/kconform-ext/         │
│                                     │         │    (vendor-specific prompts) │
└─────────────────────────────────────┘         └──────────────────────────────┘
```

**How it works**:

- Internal repo declares `KCONFORM_EXTENSION_DIR` env var pointing at its own tree.
- When `kconform detect` runs, it checks `$KCONFORM_EXTENSION_DIR/cli/ext/` before the shipped platforms.
- Internal adapter can `source "$KCONFORM_ROOT/cli/platforms/linux.sh"` and override specific functions.
- Internal skill references the public skill via markdown link + adds its own section.

**Sync strategy**:

- Internal repo tracks a specific kconform tag (`v0.X.Y`) via git submodule or vendored copy.
- When public kconform updates, internal team runs a sync PR (2-3 times a year) to pull the new version + rerun internal tests.
- Bug fixes found internally that apply generically → upstreamed as PRs (after sanitizing away vendor specifics).

**kconform core must expose clean extension points** — that's a design constraint, not an afterthought. The adapter contract (§4.2) is the primary extension API.

---

## 10. Test strategy

### 10.1 Fixtures

`tests/fixtures/` holds small self-contained Kconfig trees — just enough to exercise lint rules without being a real project. Example `tests/fixtures/uboot/`:

```
Kconfig                     # root: 20 symbols
configs/
  demo_defconfig            # a minimal, clean defconfig (baseline)
  demo_with_ghost.defconfig # has a CONFIG_FOO_BAR=y where FOO_BAR isn't defined (triggers L001)
  demo_non_minimal.defconfig # has redundant =y lines (triggers L004)
scripts/kconfig/
  merge_config.sh           # real script, not a stub
```

### 10.2 Test runner

`tests/run-tests.sh`:

- For each case under `tests/cases/<verb>/<scenario>/`:
  - `input/` has the defconfig / fragment / fixture to run against.
  - `cmd` file has the kconform command to run.
  - `expected-stdout` / `expected-stderr` / `expected-exit` compared after run.
- Golden-file style. Update goldens with `./tests/run-tests.sh --update`.

Minimum 60% line coverage on `cli/lib/` before v0.1.0 release.

### 10.3 CI matrix

- Ubuntu 22.04 / 24.04
- macOS 14 (BSD userland differences test)
- Shellcheck all `.sh` files.
- Python 3.10 / 3.11 / 3.12.

---

## 11. What the implementing Claude should build first

A walking-skeleton end-to-end in **Phase 0** (see §7), hitting every layer:

1. `cli/kconform` — parses `kconform detect` and `kconform lint <path>`.
2. `cli/lib/detect.sh` — works for U-Boot (enough to return "uboot" in a U-Boot tree).
3. `cli/platforms/uboot.sh` — implements the 5-function contract (can no-op where not needed for Phase 0).
4. `cli/lib/lint.sh` — runs rules from `cli/lib/lint-rules/`.
5. `cli/lib/lint-rules/L001-ghost-symbol.sh` — the one rule we ship first.
6. `tests/fixtures/uboot/` — toy tree.
7. `tests/cases/lint/ghost-symbol/` — one passing, one failing test case.
8. `tests/run-tests.sh` — minimal runner.
9. `README.md` — 30 lines: what, quick-start, 1 example.
10. `LICENSE` — Apache-2.0.
11. `.github/workflows/test.yml` — run shellcheck + tests on PR.

This walking skeleton proves every layer talks to the next. Everything else in Phase 1+ is filling in.

---

## 12. Open questions for the implementer (resolve before coding)

1. **Bash vs Python for CLI core?** Recommendation: bash for dispatcher + adapters (tight coupling with `make`, `merge_config.sh`); Python only for complex parsers if bash gets unwieldy. Revisit if Phase 1 feels too painful in pure bash.
2. **Should adapters be stateless?** Yes. State lives in env vars + CWD. No global config file in Phase 0.
3. **How to handle KBUILD_OUTPUT?** Inherit from user env; honor `--out=<dir>` override.
4. **Should `kconform minimize` modify files in-place?** Only with `--yes` or interactive confirmation. Default is dry-run.
5. **JSON schema for `--json` output?** Define in `docs/reference/json-schema.md`. Version it from day one (`"version": "1.0"`).
6. **Windows support?** No for v0.1. Mark as non-goal. WSL works transparently via Linux adapter.
7. **Python version floor?** 3.10. Covers what Ubuntu 22.04 LTS ships and keeps us on modern f-strings/typing.

---

## 13. Out of scope (to keep us honest)

- Schema migration between Kconfig versions — use framework's own upgrade tooling.
- UI for menuconfig (replacement) — native is fine.
- Cross-platform fragment translation (kernel fragment → buildroot fragment) — manual for now.
- Fuzzing Kconfig engines — leave to KMSAN / syzkaller.
- Commercial support tier — this is OSS; commercial offerings are downstream.

---

## 14. References

- Linux kernel Documentation/kbuild/kconfig.rst
- Linux kernel `scripts/kconfig/merge_config.sh` (commit-stable since ~2012)
- Buildroot manual: Extending Buildroot / BR2_EXTERNAL
- OpenWrt Developer Guide: config and diffconfig
- U-Boot README section on configuration (cross-refs Kconfig docs)

---

## 15. Changelog

- v0.1 (2026-04-22) — initial draft. Covers problem, scope, architecture, phased plan, open-source hygiene, internal-companion pattern. Ready for implementer to start Phase 0.
