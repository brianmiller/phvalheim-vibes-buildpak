# syntax=docker/dockerfile:1
#
# Builder for the Hugin's Vibes Build Pak (PhValheim Server 2.59, design section 8).
#
# The output is a DIRECTORY (/pak), not an image: build.sh exports the `pak` stage
# with --output type=local and tars it. The pak is extracted on the server into
# /opt/stateful/vibes/buildpak/<version>/ inside theoriginalbrian/phvalheim-server
# (FROM ubuntu:jammy; libicu70, libssl3, libcurl4, perl, python3; NO git, NO
# dotnet, NO -dev packages) and used by uid 1000 with HOME=/opt/stateful/vibes.
#
# Rules this file follows:
#   * FROM the SAME base as the server image, so dpkg-extracted binaries link
#     against the libc/gnutls the runtime actually has.
#   * Every download is pinned (pins.env -> --build-arg) and hash-verified; no
#     "latest" is resolved here.
#   * The builder may install anything it likes; only what the RUNTIME image
#     lacks goes into /pak.
#   * Nothing from Valheim or Unity is downloaded or copied. Game assemblies are
#     harvested on the server from a world's own dedicated-server install
#     (design section 1); they are copyrighted and must not be in a GitHub release.

ARG BASE=jammy
FROM ubuntu:${BASE} AS builder

# Re-declared inside the stage: a global ARG is out of scope after FROM.
ARG BASE=jammy
ARG DOTNET_CHANNEL=8.0
ARG DOTNET_SDK_VERSION
ARG DOTNET_SDK_SHA512
ARG BEPINEX_VERSION
ARG BEPINEX_SHA256
ARG ILSPY_VERSION
ARG PUBLICIZER_VERSION
ARG REFASM_VERSION
ARG GIT_PKG_VERSION
ARG LIBCURL3_GNUTLS_PKG_VERSION
ARG LIBERROR_PERL_PKG_VERSION

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Builder-only tooling. libicu70/libssl3 are what the SDK itself needs to RUN here
# (tool install, restore); the runtime image has them too, so nothing of this is
# copied into /pak. jq writes manifest.json without hand-rolled JSON escaping.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip jq libicu70 libssl3 libgssapi-krb5-2 \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /pak /dl /facts

# ---------------------------------------------------------------------------
# dotnet/  -- Microsoft's official linux-x64 SDK, extracted (this is DOTNET_ROOT)
#
# Fetched from the exact URL the release index lists for this SDK build (the same
# URL dotnet-install.sh resolves for `--version`), then verified against the
# sha512 the index publishes. dotnet-install.sh itself performs no integrity
# check, so downloading the tarball directly and checking the hash is the
# stronger path; the version string and both hashes are recorded in the manifest.
# ---------------------------------------------------------------------------
RUN url="https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-linux-x64.tar.gz"; \
    curl -fsSL --retry 3 --retry-delay 5 -o /dl/dotnet-sdk.tar.gz "$url"; \
    echo "${DOTNET_SDK_SHA512}  /dl/dotnet-sdk.tar.gz" | sha512sum -c -; \
    sha256sum /dl/dotnet-sdk.tar.gz | cut -d' ' -f1 > /facts/dotnet-sdk.sha256; \
    mkdir -p /pak/dotnet; \
    tar -xzf /dl/dotnet-sdk.tar.gz -C /pak/dotnet; \
    rm -f /dl/dotnet-sdk.tar.gz; \
    test -x /pak/dotnet/dotnet

# The SDK runs from its own directory; nothing else in the builder may shadow it.
ENV DOTNET_ROOT=/pak/dotnet \
    PATH=/pak/dotnet:/pak/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_CLI_HOME=/tmp/dotnet-cli \
    HOME=/tmp/home

RUN mkdir -p "$HOME" "$DOTNET_CLI_HOME" \
 && dotnet --version | tee /facts/dotnet-sdk.version \
 && test "$(cat /facts/dotnet-sdk.version)" = "${DOTNET_SDK_VERSION}"

# ---------------------------------------------------------------------------
# git/  -- jammy's own git, dpkg -x'ed under git/usr, plus ONLY the shared
#          libraries the runtime image lacks.
#
# Measured against theoriginalbrian/phvalheim-server:rc (dpkg-query on 2026-10-24):
# libpcre2-8-0, libexpat1, zlib1g, perl and every dependency of libcurl3-gnutls
# (gnutls, nghttp2, rtmp, ssh, psl, ldap, brotli, idn2, zstd, krb5) are PRESENT;
# libcurl3-gnutls (git-remote-https links libcurl-gnutls.so.4, the image only has
# libcurl.so.4) and liberror-perl (Error.pm for git's perl helpers) are ABSENT.
# git-man is not shipped (man pages only). build.sh re-runs ldd inside the real
# runtime image after extraction, so a wrong assumption here fails the build.
#
# Debian installs git's ~130 builtins as HARDLINKS to one 3.6 MB binary. Hardlinks
# do not reliably survive BuildKit's local exporter or every tar consumer, and a
# broken set would balloon the pak to ~500 MB; they are rewritten as relative
# symlinks, which git dispatches on identically (it looks at argv[0]'s basename).
# ---------------------------------------------------------------------------
RUN apt-get update \
 && mkdir -p /dl/git && cd /dl/git \
 && apt-get download \
      "git=${GIT_PKG_VERSION}" \
      "libcurl3-gnutls=${LIBCURL3_GNUTLS_PKG_VERSION}" \
      "liberror-perl=${LIBERROR_PERL_PKG_VERSION}" \
 && mkdir -p /pak/git \
 && for d in /dl/git/*.deb; do dpkg -x "$d" /pak/git; done \
 && dpkg-deb -f /dl/git/git_*.deb Version | sed 's/^[0-9]*://' > /facts/git.version \
 && dpkg-deb -f /dl/git/libcurl3-gnutls_*.deb Version > /facts/libcurl3-gnutls.version \
 && dpkg-deb -f /dl/git/liberror-perl_*.deb Version > /facts/liberror-perl.version \
 && rm -rf /var/lib/apt/lists/* /dl/git \
 # docs/lintian/bash-completion are dead weight on a server with no man and no shell users
 && rm -rf /pak/git/usr/share/doc /pak/git/usr/share/lintian /pak/git/usr/share/bash-completion \
 # hardlinks -> relative symlinks (see header)
 && cd /pak/git/usr/lib/git-core \
 && find . -maxdepth 1 -type f -samefile git ! -name git -exec ln -sf git {} \; \
 && find . -maxdepth 1 -type f -samefile git-remote-https ! -name git-remote-https -exec ln -sf git-remote-https {} \; \
 && cd /pak/git/usr/bin \
 && for f in *; do [ "$f" = git ] && continue; [ "$f" -ef git ] && ln -sf git "$f" || true; done \
 && test "$(find /pak/git -type f -links +1 | wc -l)" = 0 \
 && test -x /pak/git/usr/bin/git \
 && test -x /pak/git/usr/lib/git-core/git-remote-https \
 && test -d /pak/git/usr/share/git-core/templates \
 && ls /pak/git/usr/lib/x86_64-linux-gnu/libcurl-gnutls.so.4 \
 # the builder is the same base as the runtime: a sane first check (the real one is in build.sh)
 && GIT_EXEC_PATH=/pak/git/usr/lib/git-core LD_LIBRARY_PATH=/pak/git/usr/lib/x86_64-linux-gnu \
      /pak/git/usr/bin/git --version | tee /facts/git-version.out

# ---------------------------------------------------------------------------
# tools/  -- dotnet tools with --tool-path: ilspycmd and the BepInEx publicizer.
#
# A separate NUGET_PACKAGES keeps the tool packages OUT of the pak's nuget/ cache
# (that cache is for restoring plugin projects, and is hashed into the manifest).
# The executable names are discovered from the install, never assumed, and land
# in manifest.json components.toolBins.
# ---------------------------------------------------------------------------
RUN export NUGET_PACKAGES=/tmp/nuget-tools \
 && dotnet tool install --tool-path /pak/tools ilspycmd --version "${ILSPY_VERSION}" \
 && dotnet tool install --tool-path /pak/tools BepInEx.AssemblyPublicizer.Cli --version "${PUBLICIZER_VERSION}" \
 && dotnet tool list --tool-path /pak/tools | tee /facts/tool-list.out \
 && grep -qi "^ilspycmd " /facts/tool-list.out \
 && grep -qi "^bepinex.assemblypublicizer.cli " /facts/tool-list.out \
 # the command names are the 3rd column of `dotnet tool list`
 && awk 'tolower($1)=="ilspycmd"{print $3}' /facts/tool-list.out > /facts/toolbin.ilspycmd \
 && awk 'tolower($1)=="bepinex.assemblypublicizer.cli"{print $3}' /facts/tool-list.out > /facts/toolbin.publicizer \
 && test -x "/pak/tools/$(cat /facts/toolbin.ilspycmd)" \
 && test -x "/pak/tools/$(cat /facts/toolbin.publicizer)" \
 # A tool built for an OLDER runtime (the publicizer is net6.0) does NOT roll forward to
 # 8.0 by default: measured 2026-10-24, the apphost refused with "You must install .NET
 # ... version 6.0.0". rollForward=Major in each tool's own runtimeconfig.json fixes it
 # INSIDE the pak, so the server needs no DOTNET_ROLL_FORWARD in its environment.
 && find /pak/tools/.store -name '*.runtimeconfig.json' -print -exec sh -c \
      'jq ".runtimeOptions.rollForward = \"Major\"" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \; \
 # the shims must not bake in /pak: the pak lives at /opt/stateful/vibes/buildpak/<ver> on the server
 && if find /pak/tools -maxdepth 1 -type f -exec grep -l "/pak/" {} + ; then echo "tool shim embeds the build path /pak" >&2; exit 1; fi \
 # prove each tool STARTS on this runtime (a net10.0 tool would fail right here)
 && "/pak/tools/$(cat /facts/toolbin.ilspycmd)" --version | tee /facts/ilspycmd-version.out \
 && "/pak/tools/$(cat /facts/toolbin.publicizer)" --version | tee /facts/publicizer-version.out \
 && rm -rf /tmp/nuget-tools

# ---------------------------------------------------------------------------
# bepinex/  -- BepInEx 5 core DLLs from the official linux x64 release zip.
#
# Only BepInEx/core/*.dll: the loader (libdoorstop.so, run_bepinex.sh) belongs to a
# game install, not to a compiler's reference set. Plugins compile against
# BepInEx.dll and 0Harmony.dll from here (design section 6.2: BepInEx core comes
# from the pak, never from a world, because a world may be vanilla).
# ---------------------------------------------------------------------------
RUN url="https://github.com/BepInEx/BepInEx/releases/download/v${BEPINEX_VERSION}/BepInEx_linux_x64_${BEPINEX_VERSION}.zip"; \
    curl -fsSL --retry 3 --retry-delay 5 -o /dl/bepinex.zip "$url"; \
    echo "${BEPINEX_SHA256}  /dl/bepinex.zip" | sha256sum -c -; \
    echo "${BEPINEX_SHA256}" > /facts/bepinex.sha256; \
    mkdir -p /pak/bepinex; \
    unzip -j -q /dl/bepinex.zip 'BepInEx/core/*.dll' -d /pak/bepinex; \
    rm -f /dl/bepinex.zip; \
    test -f /pak/bepinex/BepInEx.dll; \
    test -f /pak/bepinex/0Harmony.dll; \
    # HarmonyX's version is read from the DLL's own metadata (design manifest lists "harmonyx").
    # FileVersionInfo on Unix reads the managed AssemblyFileVersion attribute.
    printf '%s\n' \
      'let fv (p:string) = System.Diagnostics.FileVersionInfo.GetVersionInfo(p).FileVersion' \
      'printfn "%s" (fv "/pak/bepinex/0Harmony.dll")' > /tmp/ver.fsx; \
    dotnet fsi /tmp/ver.fsx | tr -d '\r' | tee /facts/harmonyx.version; \
    test -n "$(cat /facts/harmonyx.version)"

# ---------------------------------------------------------------------------
# nuget/  -- a warmed NUGET_PACKAGES cache, then an OFFLINE re-restore to prove it.
#
# Warm: restore the minimal net472 warmup project from nuget.org into /pak/nuget.
# Prove: restore a fresh copy into an EMPTY global-packages folder with /pak/nuget
# as the ONLY source (the global cache layout id/version/*.nupkg is also a valid
# NuGet folder feed, which is what the pak's NuGet.Config relies on). The second
# restore cannot reach the network by configuration; build.sh later repeats the
# proof inside the runtime image with --network none.
# ---------------------------------------------------------------------------
COPY warmup/ /src/warmup/
RUN export NUGET_PACKAGES=/pak/nuget \
 && dotnet restore /src/warmup/Warmup.csproj --configfile /src/warmup/NuGet.online.Config -nologo -v minimal "-p:RefAsmVersion=${REFASM_VERSION}" \
 && test -d "/pak/nuget/microsoft.netframework.referenceassemblies.net472/${REFASM_VERSION}" \
 && rm -rf /src/warmup/obj \
 && cp -r /src/warmup /tmp/offline \
 && printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<configuration>' '  <packageSources>' '    <clear />' '    <add key="pak" value="/pak/nuget" />' '  </packageSources>' '</configuration>' > /tmp/offline/NuGet.Config \
 && NUGET_PACKAGES=/tmp/nuget-empty dotnet restore /tmp/offline/Warmup.csproj --configfile /tmp/offline/NuGet.Config --no-cache -nologo -v minimal "-p:RefAsmVersion=${REFASM_VERSION}" \
 && rm -rf /tmp/offline /tmp/nuget-empty \
 # the cache must be byte-identical to what the warm-up produced; hash it for the manifest
 && (cd /pak/nuget && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1) > /facts/nuget-cache.sha256

# ---------------------------------------------------------------------------
# Static pak files: NuGet.Config (local cache first, nuget.org second) and selftest.sh.
# ---------------------------------------------------------------------------
COPY pak/NuGet.Config /pak/NuGet.Config
COPY pak/selftest.sh /pak/selftest.sh
RUN chmod 0755 /pak/selftest.sh \
 # dotnet's own SDK ships without world-read on a few files in some builds; the
 # pak is used by uid 1000 from a read-only mount, so everything must be readable.
 && chmod -R a+rX /pak \
 # trim what no plugin build or pak tool can ever use; recorded in README "trimmed"
 && rm -rf /pak/dotnet/sdk/*/FSharp /pak/dotnet/shared/Microsoft.AspNetCore.App /pak/dotnet/packs/Microsoft.AspNetCore.App.Ref \
 && du -sh /pak/* | tee /facts/du.out

# ---------------------------------------------------------------------------
# manifest.json -- written LAST so the cheap layers above stay cached.
# PAK_VERSION comes from the repo's VERSION file; BUILT_AT is passed by build.sh
# because `date` inside a cached RUN would be the date of the cached layer.
# sizeBytes is null INSIDE the pak (a tarball cannot contain its own size); the
# manifest.json release asset beside the tarball carries the real number.
# ---------------------------------------------------------------------------
ARG PAK_VERSION
ARG BUILT_AT
COPY manifest.jq /src/manifest.jq
RUN test -n "${PAK_VERSION}" && test -n "${BUILT_AT}" \
 && jq -n \
      --argjson pakFormat 1 \
      --arg version "${PAK_VERSION}" \
      --arg base "${BASE}" \
      --arg builtAt "${BUILT_AT}" \
      --arg dotnet "$(cat /facts/dotnet-sdk.version)" \
      --arg dotnetChannel "${DOTNET_CHANNEL}" \
      --arg git "$(cat /facts/git.version)" \
      --arg libcurl "$(cat /facts/libcurl3-gnutls.version)" \
      --arg liberror "$(cat /facts/liberror-perl.version)" \
      --arg bepinex "${BEPINEX_VERSION}" \
      --arg harmonyx "$(cat /facts/harmonyx.version)" \
      --arg publicizer "${PUBLICIZER_VERSION}" \
      --arg ilspycmd "${ILSPY_VERSION}" \
      --arg refasm "${REFASM_VERSION}" \
      --arg nugetCache "$(cat /facts/nuget-cache.sha256)" \
      --arg binIlspy "tools/$(cat /facts/toolbin.ilspycmd)" \
      --arg binPub "tools/$(cat /facts/toolbin.publicizer)" \
      --arg shaDotnet "$(cat /facts/dotnet-sdk.sha256)" \
      --arg shaBepinex "$(cat /facts/bepinex.sha256)" \
      -f /src/manifest.jq > /pak/manifest.json \
 && cat /pak/manifest.json \
 # the builder is jammy like the runtime; a failing selftest here saves a 200 MB export
 && /pak/selftest.sh

# The exported artefact: only /pak, nothing from the builder.
FROM scratch AS pak
COPY --from=builder /pak /
