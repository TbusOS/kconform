# SPDX-License-Identifier: Apache-2.0
#
# Fixture Makefile for kconform tests. Deliberately does NOT mention U-Boot
# in the header — the real-world regression this fixture guards against was
# a detector that grep-ed the Makefile for "u-boot" in its first 40 lines.
# Upstream U-Boot's Makefile (inherited from the Linux kernel) has no such
# marker, so that heuristic rejected real trees. The detector must rely on
# structural signals (configs/ + cmd/ + Kconfig + Makefile at root), which
# this fixture now exercises.

VERSION = 0
PATCHLEVEL = 0
SUBLEVEL = 0
EXTRAVERSION =
NAME =

.PHONY: help
help:
	@echo "kconform test fixture — not a real build system."
