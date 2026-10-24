# jq program that writes the pak's manifest.json (builder-only; see Dockerfile's
# last RUN for the --arg bindings). Kept out of the Dockerfile so it can span lines.
#
# Shape follows design section 8 verbatim, plus:
#   components.toolBins   the executable names `dotnet tool install` produced, so
#                         the server never guesses them (env.php probes these)
#   sha256                of every archive the builder downloaded
#   sizeBytes             null here; the release-asset copy beside the tarball
#                         carries the real number (a tarball cannot contain its size)
{
  pakFormat: $pakFormat,
  version: $version,
  base: $base,
  arch: "x64",
  builtAt: $builtAt,
  components: {
    "dotnet-sdk": $dotnet,
    "dotnet-channel": $dotnetChannel,
    "git": $git,
    "libcurl3-gnutls": $libcurl,
    "liberror-perl": $liberror,
    "bepinex": $bepinex,
    "harmonyx": $harmonyx,
    "publicizer": $publicizer,
    "ilspycmd": $ilspycmd,
    "netframework-referenceassemblies": $refasm,
    "nuget-cache": $nugetCache,
    "toolBins": { "ilspycmd": $binIlspy, "publicizer": $binPub }
  },
  sha256: {
    "dotnet-sdk-tarball": $shaDotnet,
    "bepinex-zip": $shaBepinex
  },
  sizeBytes: null,
  selftest: "selftest.sh"
}
