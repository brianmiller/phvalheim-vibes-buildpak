#!/bin/bash
# Build Pak self-test (design section 8: "prints every component's version;
# non-zero if any is missing").
#
# Runs with ONLY the pak's own environment, derived from this script's location,
# so it works wherever the pak is extracted (/opt/stateful/vibes/buildpak/<ver> on
# the server, /pak in the builder) and as any uid (the server runs it as
# phvalheim, uid 1000, with the pak on a read-only path). Every variable set here
# mirrors container/engine/tools/vibes/lib/env.php on the server; if one changes,
# change both.
#
# Usage:
#   selftest.sh            run every check, print component=version lines
#   selftest.sh env        print the pak environment as `export K=V` lines
#                          (build.sh's smoke build does eval "$(selftest.sh env)")
#   SELFTEST_NETWORK=1 selftest.sh
#                          additionally prove git-remote-https reaches github.com
#
# Exit status: 0 when every component works; otherwise non-zero and the LAST line
# on stderr names the first missing or broken component.
set -euo pipefail

PAK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# HOME must be writable: dotnet writes $HOME/.dotnet and $HOME/.nuget on first run and
# git reads $HOME/.gitconfig. The pak itself may be read-only, so unless the caller
# hands us one (SELFTEST_HOME) we use a throw-away directory under TMPDIR.
CLEANUP_HOME=""
if [ -n "${SELFTEST_HOME:-}" ]; then
  HOME="$SELFTEST_HOME"
else
  HOME="$(mktemp -d "${TMPDIR:-/tmp}/vibes-selftest.XXXXXX")"
  CLEANUP_HOME="$HOME"
fi
export HOME
cleanup() { [ -n "$CLEANUP_HOME" ] && rm -rf "$CLEANUP_HOME" || true; }
trap cleanup EXIT

export PATH="$PAK/dotnet:$PAK/tools:$PAK/git/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DOTNET_ROOT="$PAK/dotnet"
export DOTNET_CLI_HOME="$HOME"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
# libicu70 is in the jammy image, so globalization stays on (design section 6).
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0
export NUGET_PACKAGES="$PAK/nuget"
export GIT_EXEC_PATH="$PAK/git/usr/lib/git-core"
export GIT_TEMPLATE_DIR="$PAK/git/usr/share/git-core/templates"
# libcurl-gnutls.so.4 (git-remote-https) is the one library the runtime image lacks.
export LD_LIBRARY_PATH="$PAK/git/usr/lib/x86_64-linux-gnu:$PAK/git/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Error.pm (liberror-perl) for git's perl helpers (git add -p on 2.34 is still perl).
export PERL5LIB="$PAK/git/usr/share/perl5${PERL5LIB:+:$PERL5LIB}"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# A NAMED MUTEX (NuGet's "NuGet-Migrations", taken by every restore) is backed by a file that
# .NET 8 on Linux puts under $XDG_RUNTIME_DIR -- or, when that is unset, under the user's
# /etc/passwd HOME, which must already exist and be writable (coreclr pal/sharedmemory.cpp).
# In the server image uid 1000's passwd home is /opt, owned by root, so without this every
# build died with "The system cannot open the device or file specified : 'NuGet-Migrations'"
# while the same build as root passed. A private, writable, container-local directory.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/vibes-run-$(id -u)}"
mkdir -p -m 0700 "$XDG_RUNTIME_DIR"

if [ "${1:-}" = "env" ]; then
  for v in PATH DOTNET_ROOT DOTNET_CLI_HOME DOTNET_CLI_TELEMETRY_OPTOUT DOTNET_NOLOGO \
           DOTNET_SKIP_FIRST_TIME_EXPERIENCE DOTNET_SYSTEM_GLOBALIZATION_INVARIANT \
           NUGET_PACKAGES GIT_EXEC_PATH GIT_TEMPLATE_DIR LD_LIBRARY_PATH PERL5LIB LANG LC_ALL XDG_RUNTIME_DIR; do
    printf 'export %s=%q\n' "$v" "${!v}"
  done
  # the caller keeps its own HOME; we only created a scratch one for ourselves
  exit 0
fi

fail() { echo "selftest: FAILED: $*" >&2; exit 1; }

# A tiny JSON field reader so this stays plain bash (the runtime image has python3,
# the builder does not; neither is needed for a flat string field).
mf() { sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$PAK/manifest.json" | head -1; }

[ -f "$PAK/manifest.json" ] || fail "manifest.json missing"
PAKVER="$(mf version)"; [ -n "$PAKVER" ] || fail "manifest.json has no version"
echo "pak=$PAKVER"

# --- dotnet --------------------------------------------------------------
[ -x "$PAK/dotnet/dotnet" ] || fail "dotnet: $PAK/dotnet/dotnet missing or not executable"
DOTNET_VER="$(dotnet --version 2>&1)" || fail "dotnet: 'dotnet --version' failed: $DOTNET_VER"
[ "$DOTNET_VER" = "$(mf dotnet-sdk)" ] || fail "dotnet: runs $DOTNET_VER but manifest says $(mf dotnet-sdk)"
echo "dotnet=$DOTNET_VER"

# --- git -----------------------------------------------------------------
[ -x "$PAK/git/usr/bin/git" ] || fail "git: $PAK/git/usr/bin/git missing"
[ -x "$GIT_EXEC_PATH/git-remote-https" ] || fail "git: git-remote-https missing from GIT_EXEC_PATH"
[ -d "$GIT_TEMPLATE_DIR" ] || fail "git: templates dir missing ($GIT_TEMPLATE_DIR)"
GIT_VER="$(git --version 2>&1)" || fail "git: 'git --version' failed: $GIT_VER"
# The dynamic loader is the oracle for "every shared library is present": a missing
# soname shows up as "not found" and would otherwise only surface on the first push.
if command -v ldd >/dev/null 2>&1; then
  for bin in "$PAK/git/usr/bin/git" "$GIT_EXEC_PATH/git-remote-https"; do
    missing="$(ldd "$bin" 2>&1 | awk '/not found/{print $1}' | tr '\n' ' ')"
    [ -z "$missing" ] || fail "git: $(basename "$bin") needs libraries the image lacks: $missing"
  done
fi
# git must be able to create and commit in a repo (templates, perl-free path).
t="$HOME/selftest-repo"; rm -rf "$t"; mkdir -p "$t"
( cd "$t" && git init -q . && git -c user.name=selftest -c user.email=selftest@localhost commit -q --allow-empty -m selftest ) \
  || fail "git: init/commit in a scratch repo failed"
rm -rf "$t"
echo "git=${GIT_VER#git version }"
if [ "${SELFTEST_NETWORK:-0}" = "1" ]; then
  # The real oracle for git-remote-https: TLS to github.com through libcurl-gnutls.
  out="$(git ls-remote https://github.com/brianmiller/phvalheim-server.git HEAD 2>&1)" \
    || fail "git: ls-remote over https failed: $out"
  echo "git-remote-https=ok"
fi

# --- tools (ilspycmd, publicizer) ----------------------------------------
# Executable names come from the manifest (components.toolBins), never guessed.
ILSPY_BIN="$(sed -n 's/.*"ilspycmd":[[:space:]]*"\(tools\/[^"]*\)".*/\1/p' "$PAK/manifest.json" | head -1)"
PUB_BIN="$(sed -n 's/.*"publicizer":[[:space:]]*"\(tools\/[^"]*\)".*/\1/p' "$PAK/manifest.json" | head -1)"
[ -n "$ILSPY_BIN" ] && [ -x "$PAK/$ILSPY_BIN" ] || fail "ilspycmd: toolBins entry '$ILSPY_BIN' missing or not executable"
[ -n "$PUB_BIN" ] && [ -x "$PAK/$PUB_BIN" ] || fail "publicizer: toolBins entry '$PUB_BIN' missing or not executable"
ILSPY_OUT="$("$PAK/$ILSPY_BIN" --version 2>&1)" || fail "ilspycmd: '--version' failed (does its target framework run on this runtime?): $ILSPY_OUT"
ILSPY_VER="$(printf '%s\n' "$ILSPY_OUT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$ILSPY_VER" ] || fail "ilspycmd: could not parse a version from: $ILSPY_OUT"
echo "ilspycmd=$ILSPY_VER"
PUB_OUT="$("$PAK/$PUB_BIN" --version 2>&1)" || fail "publicizer: '--version' failed (does its target framework run on this runtime?): $PUB_OUT"
PUB_VER="$(printf '%s\n' "$PUB_OUT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$PUB_VER" ] || fail "publicizer: could not parse a version from: $PUB_OUT"
echo "publicizer=$PUB_VER"

# --- bepinex -------------------------------------------------------------
for dll in BepInEx.dll 0Harmony.dll Mono.Cecil.dll; do
  [ -f "$PAK/bepinex/$dll" ] || fail "bepinex: $dll missing"
done
echo "bepinex=$(mf bepinex)"
echo "harmonyx=$(mf harmonyx)"

# --- nuget cache ---------------------------------------------------------
[ -d "$NUGET_PACKAGES/microsoft.netframework.referenceassemblies.net472" ] \
  || fail "nuget: reference assemblies for net472 missing from $NUGET_PACKAGES"
[ -f "$PAK/NuGet.Config" ] || fail "nuget: NuGet.Config missing"
echo "nuget-cache=$(mf nuget-cache)"

echo "selftest=ok"
