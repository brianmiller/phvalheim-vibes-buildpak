#!/bin/bash
# Build the Hugin's Vibes Build Pak and PROVE it works in the real runtime image.
#
#   ./build.sh                 full build + oracles -> out/
#   SKIP_BUILD=1 ./build.sh    re-run packaging + oracles on an existing out/extracted
#
# Steps (each one fails the script):
#   1. docker build the `pak` stage from pins.env, export /pak to out/extracted
#   2. tar it: out/phvalheim-vibes-buildpak-<VERSION>-linux-x64.tar.gz (+ .sha256
#      + manifest.json with sizeBytes filled in)
#   3. ORACLE 1  selftest.sh as uid 1000 inside RUNTIME_IMAGE, pak read-only, at the
#                path the server really uses (and once more at /pak)
#   4. ORACLE 2  git-remote-https to github.com from inside the runtime image
#   5. ORACLE 3  offline (--network none) compile of the smoke plugin against the
#                pak's dotnet, NuGet cache and BepInEx DLLs, as uid 1000
#   6. print path, size, sha256
#
# Why oracles in the runtime image and not in the builder: the builder has libicu,
# libssl and whatever apt pulled in; only the server image tells the truth about
# which shared libraries the pak must carry (feedback: verify what is SERVED).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$PWD"
OUT="$ROOT/out"

# ---- inputs ---------------------------------------------------------------
[ -f pins.env ] || { echo "pins.env missing" >&2; exit 1; }
[ -f VERSION ]  || { echo "VERSION missing" >&2; exit 1; }
# pins.env is KEY=VALUE only; validate before sourcing so a stray line cannot run.
if grep -vE '^(#|$|[A-Z_][A-Z0-9_]*=[^ ]*$)' pins.env; then
  echo "pins.env: the lines above are not KEY=VALUE" >&2; exit 1
fi
set -a; . ./pins.env; set +a
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION '$VERSION' is not x.y.z" >&2; exit 1; }
RUNTIME_IMAGE="${RUNTIME_IMAGE:-theoriginalbrian/phvalheim-server:rc}"
NAME="phvalheim-vibes-buildpak-${VERSION}-linux-x64"
TARBALL="$OUT/$NAME.tar.gz"
# where the server extracts a pak (design section 3); the oracles mount it there
PAK_RUNTIME_DIR="/opt/stateful/vibes/buildpak/$VERSION"

log() { printf '\n==> %s\n' "$*"; }

# ---- 1. build + export ----------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "docker build (base=$BASE dotnet=$DOTNET_SDK_VERSION git=$GIT_PKG_VERSION bepinex=$BEPINEX_VERSION ilspycmd=$ILSPY_VERSION publicizer=$PUBLICIZER_VERSION)"
  rm -rf "$OUT/extracted"
  mkdir -p "$OUT"
  args=()
  for k in BASE DOTNET_CHANNEL DOTNET_SDK_VERSION DOTNET_SDK_SHA512 BEPINEX_VERSION BEPINEX_SHA256 \
           ILSPY_VERSION PUBLICIZER_VERSION REFASM_VERSION GIT_PKG_VERSION \
           LIBCURL3_GNUTLS_PKG_VERSION LIBERROR_PERL_PKG_VERSION; do
    [ -n "${!k:-}" ] || { echo "pins.env: $k is empty" >&2; exit 1; }
    args+=(--build-arg "$k=${!k}")
  done
  # BUILT_AT is an ARG so the (cached) component layers are not invalidated by the clock.
  BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DOCKER_BUILDKIT=1 docker build \
    --target pak \
    --output "type=local,dest=$OUT/extracted" \
    "${args[@]}" \
    --build-arg "PAK_VERSION=$VERSION" \
    --build-arg "BUILT_AT=$BUILT_AT" \
    "$ROOT"
fi
EXTRACTED="$OUT/extracted"
[ -f "$EXTRACTED/manifest.json" ] || { echo "no manifest.json in $EXTRACTED" >&2; exit 1; }
chmod -R a+rX "$EXTRACTED"   # uid 1000 in the container must read everything the host user owns

# the exporter must have kept git-core small (hardlinks were rewritten as symlinks in the Dockerfile)
gitcore_mb=$(du -sm "$EXTRACTED/git/usr/lib/git-core" | cut -f1)
[ "$gitcore_mb" -lt 40 ] || { echo "git-core is ${gitcore_mb} MB: hardlinks were expanded, the pak would bloat" >&2; exit 1; }

# ---- 2. tar + sidecars ----------------------------------------------------
log "tar -> $TARBALL"
rm -f "$TARBALL" "$TARBALL.sha256" "$OUT/manifest.json"
# --sort/--owner/--numeric-owner: a reproducible archive whose only variable is content.
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$EXTRACTED" -czf "$TARBALL" .
SIZE=$(stat -c %s "$TARBALL")
SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
( cd "$OUT" && printf '%s  %s\n' "$SHA" "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
# The release-asset manifest is the in-pak one plus the numbers only known after tar.
python3 -I - "$EXTRACTED/manifest.json" "$OUT/manifest.json" "$SIZE" "$SHA" "$NAME.tar.gz" <<'PY'
import json, sys
src, dst, size, sha, name = sys.argv[1:]
m = json.load(open(src))
m["sizeBytes"] = int(size)
m["tarball"] = {"name": name, "sha256": sha}
json.dump(m, open(dst, "w"), indent=2); open(dst, "a").write("\n")
PY
# the in-pak manifest's version must be the repo's
[ "$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$EXTRACTED/manifest.json")" = "$VERSION" ] \
  || { echo "manifest version != VERSION" >&2; exit 1; }

# ---- oracles --------------------------------------------------------------
if ! docker image inspect "$RUNTIME_IMAGE" >/dev/null 2>&1; then
  log "docker pull $RUNTIME_IMAGE"
  docker pull "$RUNTIME_IMAGE"
fi
# A writable HOME for uid 1000, OUTSIDE the read-only pak, exactly like the server
# (HOME=/opt/stateful/vibes, pak under it).
HOMEDIR="$OUT/oracle-home"
rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR/downloads"; chmod 0777 "$HOMEDIR" "$HOMEDIR/downloads"

run_rt() {  # run_rt <extra docker args...> -- <cmd...>
  local dargs=()
  while [ "$1" != "--" ]; do dargs+=("$1"); shift; done; shift
  docker run --rm -u 1000:1000 \
    -v "$HOMEDIR:/opt/stateful/vibes" \
    -v "$EXTRACTED:$PAK_RUNTIME_DIR:ro" \
    -e HOME=/opt/stateful/vibes -e TMPDIR=/opt/stateful/vibes/downloads \
    "${dargs[@]}" "$RUNTIME_IMAGE" "$@"
}

log "ORACLE 1: selftest.sh as uid 1000 in $RUNTIME_IMAGE, pak read-only at $PAK_RUNTIME_DIR"
run_rt -e SELFTEST_HOME=/opt/stateful/vibes -- "$PAK_RUNTIME_DIR/selftest.sh" | tee "$OUT/selftest.out"
grep -qx 'selftest=ok' "$OUT/selftest.out"

log "ORACLE 1b: selftest.sh with the pak at /pak (catches a path baked in at build time)"
docker run --rm -u 1000:1000 -v "$EXTRACTED:/pak:ro" -v "$HOMEDIR:/home" -e HOME=/home "$RUNTIME_IMAGE" /pak/selftest.sh >/dev/null

log "ORACLE 2: git-remote-https to github.com from inside the runtime image"
run_rt -e SELFTEST_HOME=/opt/stateful/vibes -e SELFTEST_NETWORK=1 -- "$PAK_RUNTIME_DIR/selftest.sh" | grep -x 'git-remote-https=ok'
# ldd verdict, verbatim, for the report: every library git needs must resolve in THIS image
run_rt -- bash -c "export LD_LIBRARY_PATH=$PAK_RUNTIME_DIR/git/usr/lib/x86_64-linux-gnu; for b in $PAK_RUNTIME_DIR/git/usr/bin/git $PAK_RUNTIME_DIR/git/usr/lib/git-core/git-remote-https; do echo \"ldd \$(basename \$b): \$(ldd \$b | grep -c 'not found') not found\"; ldd \$b | grep 'not found' || true; done; echo \"libcurl-gnutls -> \$(ldd $PAK_RUNTIME_DIR/git/usr/lib/git-core/git-remote-https | awk '/libcurl-gnutls/{print \$3}')\"" | tee "$OUT/ldd.out"
! grep -q 'not found$' "$OUT/ldd.out" || { echo "git needs a library the runtime image lacks" >&2; exit 1; }

log "ORACLE 3: offline smoke build of the warmup plugin (--network none, uid 1000)"
rm -rf "$HOMEDIR/smoke"; cp -r "$ROOT/warmup" "$HOMEDIR/smoke"; chmod -R a+rwX "$HOMEDIR/smoke"
run_rt --network none -- bash -euo pipefail -c "
  eval \"\$($PAK_RUNTIME_DIR/selftest.sh env)\"
  cd /opt/stateful/vibes/smoke
  dotnet build Warmup.csproj -c Release -nologo -v minimal --disable-build-servers \
    --configfile $PAK_RUNTIME_DIR/NuGet.Config \
    -p:BepInExDir=$PAK_RUNTIME_DIR/bepinex -p:RefAsmVersion=$REFASM_VERSION
  test -f bin/Release/net472/VibesSmoke.dll
  echo \"smoke: \$(stat -c %s bin/Release/net472/VibesSmoke.dll) bytes\"
  # the DLL must reference BepInEx and 0Harmony (proves the HintPaths resolved, not a stub build)
  $PAK_RUNTIME_DIR/tools/ilspycmd -il bin/Release/net472/VibesSmoke.dll | grep -E '^\.assembly extern (BepInEx|0Harmony)' | sort
" | tee "$OUT/smoke.out"
grep -q '^smoke: ' "$OUT/smoke.out"
grep -q 'assembly extern BepInEx' "$OUT/smoke.out"
grep -q 'assembly extern 0Harmony' "$OUT/smoke.out"
rm -rf "$HOMEDIR/smoke"

# ---- 6. result ------------------------------------------------------------
log "RESULT"
echo "tarball: $TARBALL"
echo "size:    $SIZE bytes ($(( SIZE / 1024 / 1024 )) MiB)"
echo "sha256:  $SHA"
echo "sidecar: $TARBALL.sha256  $OUT/manifest.json"
