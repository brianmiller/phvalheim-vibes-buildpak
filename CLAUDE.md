# Build Pak architecture for coding agents

Read [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md) first. Brian's
explicit approval of the reviewed revision is required before any main/master
merge. GitHub Issues is the sole work tracker; dynamic-page review is mandatory
for every contribution. These rules apply to all coding agents, not only Claude.

## Inputs and outputs

| Path | Responsibility |
| --- | --- |
| `pins.env` | Component pins, archive hashes, base distro, SDK channel, runtime image used by checks |
| `VERSION` | Pak version; release changes belong to Brian |
| `Dockerfile` | Builds components and exports `/pak` through the scratch `pak` stage |
| `manifest.jq` | Manifest schema and component/tool names |
| `pak/selftest.sh` | Shipped self-test and environment derived from the extracted location |
| `pak/NuGet.Config` | Local cache first, then nuget.org |
| `warmup/` | Smoke plugin using BepInEx/Harmony, not Valheim/Unity assemblies |
| `build.sh` | Local build, packaging, sidecars, and runtime-image checks |
| `check-upstreams.sh` | Proposed pins; `--write` also rewrites pins and may bump version |
| `.github/workflows/release.yml` | Tag publication plus scheduled/manual build and upstream PR updates |
| `out/` | Generated, ignored build output and validation evidence |

Read [README.md](README.md) for the layout and
[server design](https://github.com/brianmiller/phvalheim-server/blob/master/docs/HUGINS-VIBES-DESIGN.md)
for integration. The server consumer is under
[`container/engine/tools/vibes/`](https://github.com/brianmiller/phvalheim-server/tree/master/container/engine/tools/vibes),
including `lib/env.php`. Read the actual consumer before changing a contract.

## Compatibility rules

- Keep component pins in `pins.env`; do not silently resolve newer binaries during
  builds or weaken checksum verification to make an old pin build.
- `base` must match the server distro. SDK channel and tool target frameworks must
  be compatible. Treat base/channel/runtime changes as explicit compatibility work.
- Layout/environment contract changes require coordination with the server and a
  reviewed `pakFormat` decision. Do not bump it for an ordinary component patch.
- The extracted manifest and external release manifest differ: `build.sh` adds
  tarball name/hash and size to the external copy after packaging. Keep them coherent.
- Tool executable names are described in `components.toolBins`; consumers must not
  guess. Self-test environment and server `lib/env.php` must agree.
- Validate as uid 1000 with a read-only pak and writable scratch home, at both the
  server path and `/pak`. Root-only or builder-only success is insufficient.
- The offline warmup build must use the bundled cache and actually reference
  BepInEx and Harmony. It does not prove live Unity or Vibes integration.
- Never bundle Valheim/Unity game assemblies. The server obtains them from its
  own world installation. The pak contains compiler references, not a game install.
- Do not manually edit generated output or replace published release assets.

Use the [validation table](CONTRIBUTING.md#implement-and-validate) to select checks.
There is no automatic package build on PR events in the existing workflow; report
what was actually run. A manual workflow dispatch also mutates the upstream bump
branch/PR and is not a substitute for local validation.
