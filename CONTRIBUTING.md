# Contributing

The most valuable contribution to this project is not code. It is a report from
a MacBook that is not a MacBookAir7,2 — see [Hardware reports](#hardware-reports).

## Before you start

Read [CLAUDE.md](CLAUDE.md). It is written for AI assistants but it is the
architecture document for the repository, and its "Deliberate decisions"
section records why several things that look wrong are the way they are. A
change that reverses one of those is not automatically unwelcome, but it needs
to argue with the reasoning that is already written down.

## Hardware reports

This project has been validated in depth on exactly one machine. Everything
else in the supported range — MacBookPro11,x, MacBook8,1, the rest of the
2013–2015 line — rests on code review and on a sensor-detection path that has
only been exercised on one sensor.

If you have any other model:

```bash
sudo ./tests/hw-validate.sh          # a few minutes, one section per open item
./scripts/collect-diagnostics.sh     # one file to attach
```

Open a **Hardware report** issue with the output. A failing report is as useful
as a passing one; several entries under "Validation" in
[`src/facetimehd/DOWNSTREAM.md`](src/facetimehd/DOWNSTREAM.md) are waiting on
exactly this.

## Code

```bash
# What CI runs
shellcheck -x --source-path=SCRIPTDIR \
    setup.sh \
    scripts/install.sh scripts/uninstall.sh scripts/macbook-tune.sh \
    scripts/extract-firmware.sh scripts/collect-diagnostics.sh \
    packaging/build-deb.sh packaging/build-rpm.sh \
    tests/build-driver.sh tests/smoke-capture.sh tests/hw-validate.sh \
    tests/script-smoke.sh

./tests/build-driver.sh                        # every headers tree present
W=1 WERROR=1 ./tests/build-driver.sh           # warnings are errors
SPARSE=1 W=1 ./tests/build-driver.sh           # semantic checks
./tests/script-smoke.sh                        # installer/uninstaller plumbing
```

Every tracked `*.sh` outside `scripts/lib/` must appear in that shellcheck
list; CI fails if one does not.

Conventions:

- Shell is `#!/usr/bin/env bash` with `set -euo pipefail`, executable, and
  shellcheck-clean.
- Everything must be idempotent, reversible, and leave the system bootable if
  interrupted.
- Commit messages are `type: brief description` — `fix:`, `feat:`, `docs:`,
  `refactor:`, `test:`, `chore:`.

### Driver changes

**A change to `src/facetimehd/` is not finished until `DOWNSTREAM.md` says
why.** The fork carries no patch headers, so that file is the entire review
record for its divergence from upstream. Describe the reasoning, not the diff,
and write it as the current state of the driver rather than as a history of how
it got there.

Please also propose driver fixes upstream at
[patjak/facetimehd](https://github.com/patjak/facetimehd) where they apply
there. This fork exists because upstream is quiet, not because it is wrong.

### Guessing at firmware

Several ISP commands have payload layouts Apple never documented. The rules
that make working on them acceptable are in
[`src/facetimehd/FIRMWARE-REVERSE-ENGINEERING.md`](src/facetimehd/FIRMWARE-REVERSE-ENGINEERING.md),
"Rules for any reimplementation". Read them first — the short version is:

- A registered V4L2 control's default is replayed at every `STREAMON`, so
  registering one is the same as sending its command unprompted. That is what
  hard-locked the validation machine.
- Firmware does not enforce a per-opcode minimum request length, so a payload
  that is too short makes it read past the request. A wrong guess must be
  refused, not destructive.
- GET first. A recovered value may reach V4L2 only as a **read-only** control,
  and only once hardware evidence supports its meaning.

Anything inferred goes in DOWNSTREAM.md's "Validation" list
until hardware confirms it.

## Licensing

The whole project is GPL-2.0-only, including scripts, tests and documentation.
Derived code keeps its upstream attribution header — do not reword provenance
away.
