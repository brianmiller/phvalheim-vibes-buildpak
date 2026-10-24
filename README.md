# phvalheim-vibes-buildpak

The **Build Pak** for Hugin's Vibes (PhValheim Server 2.59+): a single tarball
holding the toolchain the server needs to compile, decompile, publicize and
version-control BepInEx plugins, built so it can be dropped into a running
`theoriginalbrian/phvalheim-server` container that has **no git, no dotnet, no
node and no -dev packages** (the image went on a CVE diet in 2.58). The pak is
opt-in: an operator who never vibes never downloads it.

Design: `phvalheim-server/docs/HUGINS-VIBES-DESIGN.md`, sections 1, 3, 6 and 8.

## What is in it

```
phvalheim-vibes-buildpak-<ver>-linux-x64.tar.gz
  manifest.json      pakFormat, version, base, arch, builtAt, components{...}, sha256{...}, selftest
  selftest.sh        prints component=version for everything below; non-zero naming the first broken one
  dotnet/            Microsoft's linux-x64 .NET SDK (DOTNET_ROOT); FSharp + ASP.NET pieces trimmed
  git/usr/           jammy's git, dpkg -x'ed, plus ONLY the libraries the runtime image lacks:
                     libcurl-gnutls.so.4 (git-remote-https) and Error.pm (liberror-perl)
  tools/             dotnet tools installed with --tool-path: ilspycmd, assembly-publicizer
  bepinex/           BepInEx/core/*.dll from the official BepInEx 5 linux x64 release zip
  nuget/             a warmed NUGET_PACKAGES cache (Microsoft.NETFramework.ReferenceAssemblies for net472)
  NuGet.Config       sources: the nuget/ folder first (relative path), nuget.org second
```

Every version is pinned in `pins.env`; the resulting versions and the sha256 of
every archive downloaded are in `manifest.json`. `components.toolBins` records the
tool executable names (`tools/ilspycmd`, `tools/assembly-publicizer`) so the server
never has to guess them.

### What is NOT in here, and why

- **No Valheim or Unity assemblies, no game files.** `assembly_valheim.dll`,
  `UnityEngine.*.dll` and friends are copyrighted (Iron Gate, Unity Technologies)
  and cannot be redistributed in a GitHub release. The server **harvests** them
  from a world's own dedicated-server install (`<world>/game/valheim_server_Data/
  Managed/`, present on every PhValheim world) and publicizes them locally with
  the publicizer from this pak. The smoke plugin in `warmup/` therefore compiles
  against `BepInEx.dll` + `0Harmony.dll` only.
- **No BepInEx loader** (`libdoorstop.so`, `run_bepinex.sh`): the pak is a
  compiler's reference set, not a game install.
- **No templates, knowledge or agent rules**: text that must track the server
  ships inside the server image and versions with it (design section 1).
- **Nothing the runtime image already has** (libicu, libssl, libpcre2, perl,
  zlib, gnutls ...). The missing set was *measured* with `dpkg-query`/`ldd`
  inside the runtime image, not guessed, and `build.sh` re-measures it on every
  build.

## How the server consumes it

1. `GET /repos/brianmiller/phvalheim-vibes-buildpak/releases` -> newest release
   whose `manifest.json` asset has a `pakFormat` the server accepts and a `base`
   equal to the image's distro codename.
2. Download the tarball, verify against the `.sha256` asset.
3. Extract to `/opt/stateful/vibes/buildpak/<ver>.tmp`, run `selftest.sh`,
   rename, swap the `current` symlink.
4. Every pak-backed process runs as `phvalheim` (uid 1000) with the environment
   `container/engine/tools/vibes/lib/env.php` builds -- the same one
   `selftest.sh` derives from its own location:

| variable | value |
|---|---|
| `PATH` | `<pak>/dotnet:<pak>/tools:<pak>/git/usr/bin:` + system |
| `HOME`, `DOTNET_CLI_HOME` | a writable dir (`/opt/stateful/vibes`); the pak may be read-only |
| `DOTNET_ROOT` | `<pak>/dotnet` |
| `NUGET_PACKAGES` | `<pak>/nuget` |
| `GIT_EXEC_PATH` | `<pak>/git/usr/lib/git-core` |
| `GIT_TEMPLATE_DIR` | `<pak>/git/usr/share/git-core/templates` |
| `LD_LIBRARY_PATH` | `<pak>/git/usr/lib/x86_64-linux-gnu:<pak>/git/usr/lib` |
| `PERL5LIB` | `<pak>/git/usr/share/perl5` (Error.pm for `git add -p` etc.; optional) |
| `DOTNET_CLI_TELEMETRY_OPTOUT=1`, `DOTNET_NOLOGO=1`, `DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1`, `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0`, `LANG=LC_ALL=C.UTF-8` | |

`selftest.sh env` prints exactly these as `export` lines. Builds pass
`--configfile <pak>/NuGet.Config` (or disable the `nuget.org` source for
offline operators) and `--disable-build-servers` so no MSBuild/VBCSCompiler
node outlives the job.

### Compatibility rule

- `pakFormat` (integer) is bumped **only** when the server-side layout
  expectations change (a directory moves, an env var changes meaning). The
  server lists the formats it accepts and ignores paks it cannot read.
- `base` must equal the server image's distro codename (`jammy` today). The
  dpkg-extracted git links against the base's libc/gnutls; a `noble` server
  gets a pak built with `BASE=noble` -- the same Dockerfile, one ARG, and the
  apt pins re-resolved by `check-upstreams.sh`.
- Everything else (SDK patch, BepInEx patch, tool versions) floats inside a
  `pakFormat`; the server shows "Build Pak x.y.z available" and updates in place.

## Building locally

Requirements: docker with BuildKit (`docker build --output`), bash, python3,
tar, sha256sum. ~250 MB of downloads on a cold cache.

```sh
./build.sh
```

`build.sh` builds the Dockerfile's `pak` stage from `pins.env` + `VERSION`,
exports `/pak` to `out/extracted/`, writes `out/phvalheim-vibes-buildpak-<ver>-
linux-x64.tar.gz`, its `.sha256` and a `manifest.json` with `sizeBytes` filled
in, then runs the **oracles inside the real runtime image** (`RUNTIME_IMAGE` in
`pins.env`, pulled if absent) as uid 1000 with the pak mounted read-only at the
path the server uses:

1. `selftest.sh` (also once more with the pak at `/pak`, to catch a baked-in path);
2. `git ls-remote https://github.com/...` through `git-remote-https`, plus the
   `ldd` verdict for `git` and `git-remote-https` (zero "not found");
3. an **offline** (`--network none`) `dotnet build` of `warmup/` against the pak's
   NuGet cache and BepInEx DLLs, then `ilspycmd -il` proves the output really
   references `BepInEx` and `0Harmony`.

Any failure exits non-zero. `SKIP_BUILD=1 ./build.sh` re-runs packaging and the
oracles on an existing `out/extracted`.

Testing an unreleased pak on a dev server: copy the tarball into the container's
`/opt/stateful/vibes/downloads/` (chown `phvalheim`) and point the server's
advanced `file://` pak override at it.

## Releasing

1. Change pins in `pins.env` (or merge the weekly bump PR), bump `VERSION`.
2. Commit, tag `v<VERSION>` (the workflow fails if the tag and `VERSION`
   disagree), push the tag.
3. `.github/workflows/release.yml` runs `build.sh` (with the same oracles), runs
   Trivy on the extracted pak (report uploaded; non-blocking for now, the YAML
   says why), and publishes the release with exactly three assets: the tarball,
   its `.sha256`, and `manifest.json`.

Weekly (`cron`) and on `workflow_dispatch`, `check-upstreams.sh` re-resolves
every pin -- the dotnet release index for the channel's newest SDK + sha512,
BepInEx's releases API for the newest v5 + zip sha256, nuget.org for the newest
*compatible* tool versions (a tool whose nupkg targets a `net<N>` above the SDK
channel is reported and skipped, never pinned), and `ubuntu:$BASE`'s apt for the
git pins -- and opens/refreshes one PR (`bump/pins`) bumping `pins.env` and the
patch digit of `VERSION` when a component changed. Secrets: `GITHUB_TOKEN`
only; enable "Allow GitHub Actions to create and approve pull requests" in the
repository's Actions settings for the PR step. Version bumps and the decision to
release remain a human's.

## Repository layout

```
Dockerfile          builder (FROM ubuntu:$BASE), assembles /pak; the `pak` stage is FROM scratch
manifest.jq         the manifest's shape, consumed by the Dockerfile's last RUN
build.sh            build, tar, sidecars, oracles (see above)
check-upstreams.sh  pin re-resolution for the weekly PR
pins.env            every pin, one file
VERSION             the pak's own version (x.y.z)
pak/selftest.sh     shipped at the tarball root
pak/NuGet.Config    shipped at the tarball root
warmup/             the net472 warm-up / smoke project (never shipped)
LICENSE             MIT for this repo + the notices and GPLv2 source offer for the aggregate
out/                build output (git-ignored)
```
