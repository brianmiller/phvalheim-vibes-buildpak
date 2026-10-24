#!/bin/bash
# Re-resolve every pin in pins.env against its upstream and report what moved.
#
#   ./check-upstreams.sh             print the proposed pins.env to stdout + a diff on stderr
#   ./check-upstreams.sh --write     rewrite pins.env in place (and bump VERSION's patch
#                                    number when a COMPONENT pin changed)
#
# Exit status is 0 whether or not anything changed; the verdict is on the last
# line: "CHANGED=1" or "CHANGED=0" (also appended to $GITHUB_OUTPUT when set), so
# the weekly workflow can decide whether to open a PR. Nothing here ever edits the
# Dockerfile: the Dockerfile reads pins through --build-arg, so this file IS the
# whole change, and a human reviews it as a PR before any pak is released.
#
# Human-owned pins this script never touches: BASE (must match the server image's
# distro), DOTNET_CHANNEL (an LTS choice), RUNTIME_IMAGE.
#
# Needs: bash, curl, jq, unzip, docker (to ask ubuntu:$BASE's apt for the git pins).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
set -a; . ./pins.env; set +a
WRITE=0; [ "${1:-}" = "--write" ] && WRITE=1

UA="phvalheim-vibes-buildpak-check-upstreams"
get() { curl -fsSL --retry 3 --retry-delay 5 -A "$UA" "$@"; }
# GITHUB_TOKEN lifts the anonymous 60/h rate limit on api.github.com when present (CI).
gh_get() { if [ -n "${GITHUB_TOKEN:-}" ]; then get -H "Authorization: Bearer $GITHUB_TOKEN" "$@"; else get "$@"; fi; }

note() { echo "  $*" >&2; }

# ---- .NET SDK: newest SDK on the channel + its linux-x64 tar.gz sha512 -------
note "dotnet $DOTNET_CHANNEL release index"
idx="$(get "https://builds.dotnet.microsoft.com/dotnet/release-metadata/${DOTNET_CHANNEL}/releases.json")"
NEW_DOTNET_SDK_VERSION="$(jq -r '."latest-sdk"' <<<"$idx")"
NEW_DOTNET_SDK_SHA512="$(jq -r --arg v "$NEW_DOTNET_SDK_VERSION" \
  '.releases[] | select(.sdk.version == $v) | .sdk.files[] | select(.rid == "linux-x64" and (.name | endswith(".tar.gz"))) | .hash' <<<"$idx" | head -1)"
[ "${#NEW_DOTNET_SDK_SHA512}" = 128 ] || { echo "release index has no linux-x64 sha512 for SDK $NEW_DOTNET_SDK_VERSION" >&2; exit 1; }

# ---- BepInEx: newest non-prerelease v5.x and the linux x64 zip's sha256 ------
note "BepInEx releases"
rels="$(gh_get "https://api.github.com/repos/BepInEx/BepInEx/releases?per_page=30")"
NEW_BEPINEX_VERSION="$(jq -r '[.[] | select(.draft == false and .prerelease == false and (.tag_name | startswith("v5.")))][0].tag_name | ltrimstr("v")' <<<"$rels")"
[ -n "$NEW_BEPINEX_VERSION" ] && [ "$NEW_BEPINEX_VERSION" != null ] || { echo "no BepInEx v5 release found" >&2; exit 1; }
if [ "$NEW_BEPINEX_VERSION" = "$BEPINEX_VERSION" ]; then
  NEW_BEPINEX_SHA256="$BEPINEX_SHA256"   # same artefact, same hash; do not re-download 650 KB for nothing
else
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  get -o "$tmp" "https://github.com/BepInEx/BepInEx/releases/download/v${NEW_BEPINEX_VERSION}/BepInEx_linux_x64_${NEW_BEPINEX_VERSION}.zip"
  NEW_BEPINEX_SHA256="$(sha256sum "$tmp" | cut -d' ' -f1)"
fi

# ---- dotnet tools: newest STABLE version whose target framework runs on the channel
# A tool's nupkg carries tools/<tfm>/any/; net8.0 or lower runs on an 8.0 runtime
# (lower majors roll forward), net9.0+ does not. Candidates are inspected newest
# first and the first qualifying one wins; a tool that moved to a newer TFM is
# reported but never pinned.
channel_major="${DOTNET_CHANNEL%%.*}"
newest_compatible_tool() {  # <package-id-lowercase>
  local id="$1" versions v tmp tfms major
  versions="$(get "https://api.nuget.org/v3-flatcontainer/${id}/index.json" | jq -r '.versions[]' | grep -vE -- '-' | tac)"
  tmp="$(mktemp)"
  for v in $versions; do
    get -o "$tmp" "https://api.nuget.org/v3-flatcontainer/${id}/${v}/${id}.${v}.nupkg"
    tfms="$(unzip -Z1 "$tmp" | sed -n 's#^tools/\(net[0-9][0-9.]*\)/.*#\1#p' | sort -u)"
    for t in $tfms; do
      major="${t#net}"; major="${major%%.*}"
      if [ "$major" -le "$channel_major" ]; then rm -f "$tmp"; echo "$v"; return 0; fi
    done
    note "$id $v targets '$tfms' (needs a runtime > ${DOTNET_CHANNEL}); skipped"
  done
  rm -f "$tmp"; return 1
}
note "nuget.org: ilspycmd"
NEW_ILSPY_VERSION="$(newest_compatible_tool ilspycmd)"
note "nuget.org: bepinex.assemblypublicizer.cli"
NEW_PUBLICIZER_VERSION="$(newest_compatible_tool bepinex.assemblypublicizer.cli)"
note "nuget.org: microsoft.netframework.referenceassemblies"
NEW_REFASM_VERSION="$(get https://api.nuget.org/v3-flatcontainer/microsoft.netframework.referenceassemblies/index.json | jq -r '.versions[]' | grep -vE -- '-' | tail -1)"

# ---- apt pins: what ubuntu:$BASE would install today ------------------------
note "apt candidates in ubuntu:$BASE"
pol="$(docker run --rm "ubuntu:${BASE}" sh -c 'apt-get update -qq >/dev/null 2>&1; apt-cache policy git libcurl3-gnutls liberror-perl')"
cand() { awk -v p="$1:" '$1==p{f=1;next} f&&/Candidate:/{print $2;exit}' <<<"$pol"; }
NEW_GIT_PKG_VERSION="$(cand git)"
NEW_LIBCURL3_GNUTLS_PKG_VERSION="$(cand libcurl3-gnutls)"
NEW_LIBERROR_PERL_PKG_VERSION="$(cand liberror-perl)"
for v in NEW_GIT_PKG_VERSION NEW_LIBCURL3_GNUTLS_PKG_VERSION NEW_LIBERROR_PERL_PKG_VERSION; do
  [ -n "${!v}" ] && [ "${!v}" != "(none)" ] || { echo "$v: apt returned nothing" >&2; exit 1; }
done

# ---- diff + rewrite -----------------------------------------------------------
CHANGED=0
proposed="$(mktemp)"; cp pins.env "$proposed"
for k in DOTNET_SDK_VERSION DOTNET_SDK_SHA512 BEPINEX_VERSION BEPINEX_SHA256 ILSPY_VERSION PUBLICIZER_VERSION \
         REFASM_VERSION GIT_PKG_VERSION LIBCURL3_GNUTLS_PKG_VERSION LIBERROR_PERL_PKG_VERSION; do
  nk="NEW_$k"; old="${!k}"; new="${!nk}"
  if [ "$old" != "$new" ]; then
    CHANGED=1
    echo "CHANGE $k: $old -> $new" >&2
    # sed delimiter '|' never appears in a version or hash; ':' does (apt epochs)
    sed -i "s|^$k=.*|$k=$new|" "$proposed"
  fi
done

if [ "$WRITE" = 1 ]; then
  cp "$proposed" pins.env
  if [ "$CHANGED" = 1 ]; then
    # a component moved => the next pak is a new patch release (design section 8:
    # "a new pak is released only when components changed")
    IFS=. read -r a b c < VERSION
    printf '%s.%s.%s\n' "$a" "$b" "$((c + 1))" > VERSION
    echo "VERSION -> $(cat VERSION)" >&2
  fi
else
  cat "$proposed"
fi
rm -f "$proposed"

echo "CHANGED=$CHANGED"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "changed=$CHANGED" >> "$GITHUB_OUTPUT" || true
