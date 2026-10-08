# Driver patch series

The changes in [`../src/facetimehd/`](../src/facetimehd/) as a numbered patch
series against **`patjak/facetimehd` commit `c9b063a`** (upstream `master`,
2026-10-05), one feature per patch, ordered from the lightest touch to the
most intrusive:

| # | Patch | Kind |
| --- | --- | --- |
| 1–3 | tidy, drop pre-5.15 compatibility code, logging levels | no functional change |
| 4–7 | PLL/DDR error propagation, MSI vectors, BAR bounds checks, DDR cleanup | small, local fixes |
| 8–10 | firmware data validation, command-path hardening, scatterlist mapping | robustness |
| 11 | buffer ownership and locking | streaming core |
| 12–15 | anti-banding/exposure, NV12, settable crop, frame-interval range | V4L2 features |
| 16–17 | lifecycle and runtime PM, streams surviving system suspend | power management |
| 18–21 | debugfs references, firmware readbacks, colour-temperature control, setter tests | diagnostics |

Buffer ownership (11) comes before the V4L2 features because they build on it.
Every patch builds warning-free with `W=1`, and applying all of them gives
`src/facetimehd/` byte for byte, minus the files that are not driver source
(`DOWNSTREAM.md`, `FIRMWARE-REVERSE-ENGINEERING.md`, `.gitignore`) and with
upstream's `README.md` untouched.

```bash
git clone https://github.com/patjak/facetimehd
cd facetimehd && git checkout c9b063a
git am /path/to/driver-patches/*.patch
```

This is a generated view of the driver source; the reasons for each change
are in the commit messages and in
[`../src/facetimehd/DOWNSTREAM.md`](../src/facetimehd/DOWNSTREAM.md). Nothing
in `scripts/`, `tests/` or CI reads these files.
