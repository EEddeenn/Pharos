# Pharos

A GNSS IF signal simulator in Zig 0.16: a scenario in, quantised IF samples
(IQ2, IQ4, IQ8, IQ16) or RINEX observation and position files out, for
sixteen signals of GPS, Galileo, BeiDou and GLONASS. Four tools share one
core:

| Tool | Does |
|---|---|
| `pharos-traj` | solves trajectory plans, verifies and writes internal trajectories (`.pht`), and exports KML |
| `pharos-pack` | reads a scenario JSON and the navigation data it names, validates them and packs a bundle (`.phb`) |
| `pharos-run` | generates the IF samples from a bundle |
| `pharos-obs` | writes the observation and position files of a bundle |

Each tool is a command, a static library and a generated C header
(`pharos_traj.h`, `pharos_pack.h`, `pharos_run.h`, `pharos_obs.h`),
with no dependencies beyond the Zig toolchain. Behaviour follows the
official interface control documents and file format descriptions, listed
in the documentation.

## Build

```bash
zig build -Doptimize=ReleaseFast
```

installs the four commands under `zig-out/bin`, the libraries under
`zig-out/lib` and the headers under `zig-out/include`.
`zig build wasm -Doptimize=ReleaseFast` installs `pharos_traj.wasm`,
`pharos_pack.wasm` and `pharos_obs.wasm` under `zig-out/lib`, one
WebAssembly module per product for a JavaScript host. Beside them go
`trajectory.schema.json` and `scenario.schema.json`, the JSON Schemas of
trajectory plans and scenarios. The modules require WebAssembly SIMD128
support.

## Quick start

```bash
./zig-out/bin/pharos-traj build examples/trajectories/wuhan_drive.json
./zig-out/bin/pharos-pack examples/scenarios/gps_l1ca_minimal.json
./zig-out/bin/pharos-run examples/scenarios/gps_l1ca_minimal.phb -t
./zig-out/bin/pharos-pack examples/scenarios/observation_rinex_multi_gnss.json
./zig-out/bin/pharos-obs examples/scenarios/observation_rinex_multi_gnss.phb
```

`examples/` holds nineteen scenarios, the trajectories they fly and the
navigation data they read.

## Documentation

| Part | Content |
|---|---|
| [docs/guide/](docs/guide/README.md) | Using Pharos: the four tools, trajectories, scenarios, navigation data, samples, observation files, the C API, the examples |
| [docs/gnss/](docs/gnss/README.md) | The four constellations: their signals and one implementation matrix per message, against the ICDs |
| [docs/models/](docs/models/README.md) | The models between satellite and receiver: ionosphere, troposphere, geometry, geoid, antennas and attitude |
| [docs/design/](docs/design/README.md) | How Pharos is built: architecture, data flow, engine, formats |
