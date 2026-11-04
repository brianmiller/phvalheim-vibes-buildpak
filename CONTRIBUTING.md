# Contributing to the Vibes Build Pak

This guide is for people and LLM coding agents. Start here, then read
[CLAUDE.md](CLAUDE.md) for the architecture and [README.md](README.md) for the
package layout and build behavior. The shared
[PhValheim contributor guide](https://brianmiller.github.io/phvalheim-server/contribute/)
explains the wider project.

## Brian must approve every merge

Brian Miller (`@brianmiller`) must explicitly approve the revision entering `main`
or `master`, including documentation, CI, dependency, and agent-produced changes.
Prepare and test a PR, then wait. Implementation requests, green checks, other
reviewers, and access to Brian's account do not authorize merging. New changes after
approval require renewed approval. Do not merge, enable auto-merge, push directly,
or bypass protections without Brian's explicit authorization for that action.
Never submit a review pretending to be Brian. If GitHub prevents self-approval on a
PR opened under his account, his explicit approval of the PR revision in the working
conversation can authorize an agent to perform the merge on his behalf.

[CODEOWNERS](.github/CODEOWNERS) names Brian for every file. Required code-owner
reviews and stale-approval dismissal require GitHub branch protection settings;
this file alone does not enforce them.

## Choose the right repository

This repository packages the .NET SDK, git, BepInEx reference DLLs, decompiler,
publicizer, and NuGet cache used by Hugin's Vibes. Vibes UI, prompts, agent rules,
installation, and server integration live in
[phvalheim-server](https://github.com/brianmiller/phvalheim-server).
Player launcher changes belong in
[phvalheim-client](https://github.com/brianmiller/phvalheim-client); in-game plugin
behavior belongs in [phvalheim-companion](https://github.com/brianmiller/phvalheim-companion).

## Track work in GitHub Issues

[GitHub Issues](https://github.com/brianmiller/phvalheim-vibes-buildpak/issues) is the
single source of truth for tasks, ownership, acceptance criteria, and completion
status. Search existing issues and linked follow-ups before opening another. Agree
on scope and coordinate ownership in the issue. Every PR must review and link
applicable issues, or explain why none applies to a small correction.

Keep implementation and review evidence in PRs, and architecture/setup/current
behavior in repository docs. Do not create a parallel Markdown backlog. Closing an
issue or merging a PR is not evidence of release or deployment. Follow
[SECURITY.md](SECURITY.md) for private vulnerability reports.

## Set up a disposable checkout

Use Linux x86-64, Git, Bash, Docker with BuildKit/local output support, Python 3,
GNU tar/coreutils, and standard shell utilities. The upstream inspection script
additionally uses curl, jq, and unzip. Network access is needed to download pinned
components and the runtime image; allow space for Docker layers and extracted output.
The SDK and game assemblies do not need to be installed on the host.

Fork the repository on GitHub, then substitute your account below:

```bash
git clone https://github.com/<your-account>/phvalheim-vibes-buildpak.git
cd phvalheim-vibes-buildpak
git switch -c my-change
bash -n build.sh check-upstreams.sh pak/selftest.sh
```

Keep this checkout separate from operator data. `./build.sh` replaces
`out/extracted/`, repackages output, and recreates `out/oracle-home/`. It runs
throwaway containers with its own output mounts; it does not publish a release.
Never redirect those mounts to a live server's data. Read [the local build
section](README.md#building-locally) before running it.

## Implement and validate

Keep one focused change per PR. For behavior changes, include a regression check
that detects the original failure. Validate against the server runtime image,
not only the builder image: extra builder dependencies can hide missing libraries.

| Change | Required evidence |
| --- | --- |
| Docs or contributor metadata only | Check links, paths, and changed commands against source; `git diff --check`. No package rebuild or gameplay required. |
| Shell scripts | `bash -n build.sh check-upstreams.sh pak/selftest.sh`, relevant failure-path checks, and full build when packaging/runtime behavior is affected. |
| Dockerfile, component pins, manifest, NuGet cache, or self-test | `./build.sh` from a fresh checkout/output; record all runtime-image checks and output checksums. |
| Upstream resolver | Exercise changed selection/write behavior in a disposable checkout; inspect proposed pins, compatible tool frameworks, and resulting version diff. Run the full build for selected component changes. |
| Server/package contract | Name both revisions and runtime image ID/digest; validate the affected installation/environment/manifest behavior in a disposable server environment. |

For a full build and verification:

```bash
./build.sh
(cd out && sha256sum -c phvalheim-vibes-buildpak-*-linux-x64.tar.gz.sha256)
git diff --check
```

Success means exit zero, a final `RESULT`, and the tarball, `.sha256`, and external
`manifest.json` under `out/`. Keep `out/selftest.out`, `out/ldd.out`, and
`out/smoke.out` as evidence. The build checks self-test operation as uid 1000 with a
read-only pak at two locations, git HTTPS and library resolution in the runtime
image, and an offline smoke build referencing BepInEx and Harmony. Record the image
actually used: `RUNTIME_IMAGE` comes from `pins.env`, which the script sources and
which overrides a same-named shell environment variable. A cached mutable tag may
be used; record its ID/digest rather than claiming the latest remote image was tested.

`SKIP_BUILD=1 ./build.sh` only repackages and rechecks existing `out/extracted`.
It is not proof that changed Dockerfile, pins, or source were rebuilt.
`./check-upstreams.sh` reports proposed pins without rewriting repository files;
it still downloads data and runs Docker. `--write` changes pins and may bump
`VERSION`, so use it only for scoped resolver/dependency work in a disposable
checkout. Release version decisions remain Brian's; do not include incidental
version changes in ordinary contributions.

The existing [release workflow](.github/workflows/release.yml) runs on tags, manual
dispatch, and a schedule, **not pull requests**. Do not claim a PR has package CI
coverage just because it has no failing checks. Manual dispatch also runs the
upstream job, which can push a branch and open/update a PR. Do not use it as a
read-only test command. Its Trivy report is non-blocking; a green workflow does
not establish that the package has no vulnerabilities.

Separate build evidence from live Vibes/gameplay evidence. Missing dependencies,
network failures, unavailable platforms, and skipped checks are unverified. Record
limitations and sanitized results in the PR; never invent a successful run.

## Always review dynamic pages and status content

Every contribution must review these areas, including code-only and docs-only PRs:

- This README, agent/contributor guides, component/compatibility descriptions, and
  [GitHub Issues](https://github.com/brianmiller/phvalheim-vibes-buildpak/issues).
- The [server website sources](https://github.com/brianmiller/phvalheim-server/tree/master/website/docs):
  landing page, contributor chooser, Vibes setup/build guidance, download/install
  descriptions, dynamic links and static fallbacks, and version references.
- Server portal/admin guidance and related repository docs affected by the change.

Update affected content. Record paths reviewed and changes made, or specific
reasons each applicable area needs no update. Check rendered behavior when output
changes; a rebuild or dynamic API does not rewrite stale descriptions. Report
unavailable checks as unverified; unexplained `N/A` is insufficient. For another
repository, prepare a linked PR or name the follow-up and owner for Brian's review.
Keep implemented, merged, released, and deployed status distinct. Do not advertise
unreleased behavior as available. This review does not authorize releases,
deployment, version bumps, or issue closure.

## Open a PR

Use [the PR template](.github/PULL_REQUEST_TEMPLATE.md). Include the user-visible
change, related issues/PRs and revisions, validation commands/results, package and
runtime identities when applicable, documentation review, and remaining gaps.
Then wait for Brian's approval. Humans submitting agent work must review the diff
and results themselves.

Do not commit `out/`, credentials, private logs, personal data, or Valheim/Unity
game files. Preserve [LICENSE](LICENSE) and third-party notices/source offers.
Local builds are allowed; tags, version bumps, release assets and installs on live
servers require Brian's separate authorization. Never replace an already-published
artifact with a different rebuild under the same identity.
