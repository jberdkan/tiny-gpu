# Cadence Innovus — OSU05 layout signoff (gpu)

Place-and-route signoff results for the full `gpu` taken through **Cadence
Innovus** on the **OSU05 / AMI 0.5 µm** standard-cell library (3 metal layers).
OSU standard cells are openly available, so these results are publishable.

> The proprietary IBM cmos8hp outputs (netlist / SDF / GDS / library files) are
> **not** included here — those are under a foundry NDA.

## Results

| Check | Command | Result |
|-------|---------|--------|
| DRC | `verify_drc` | **No DRC violations were found** |
| Connectivity | `verify_connectivity` | **Found no problems or warnings** |

- `gpu.geom.rpt` — Innovus geometry / DRC report
- `gpu.conn.rpt` — Innovus connectivity report
- `osu05_gpu_layout.png` — routed layout (green = std cells + routing, blue/red =
  power grid, yellow = I/O pins)

Generated with Cadence Innovus 18.10 (see `../scripts/` for the flow).
