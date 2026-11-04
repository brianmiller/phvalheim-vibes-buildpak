# For AI coding assistants

Read [CONTRIBUTING.md](CONTRIBUTING.md), then [CLAUDE.md](CLAUDE.md), before editing.
These instructions apply to every coding agent and human contributor.

- **Brian Miller (`@brianmiller`) must explicitly approve the reviewed revision before
  any merge to `main` or `master`.** Prepare and validate a PR, then wait. An
  implementation request, green CI, another review, or access to his credentials
  is not merge approval. Changes after approval require renewed approval.
  Never impersonate Brian's review. Once Brian explicitly authorizes the merge,
  an agent may perform it on his behalf. No direct pushes, auto-merge, or protection
  bypass without his explicit authorization for that action.
- **GitHub Issues is the sole work tracker.** Review and link affected issues;
  do not maintain duplicate Markdown task/status lists.
- **Review dynamic pages and status content for every contribution**, including
  code-only and docs-only work. Update affected content and record reviewed paths,
  changes, or specific reasons no update is needed. Follow the
  [review procedure](CONTRIBUTING.md#always-review-dynamic-pages-and-status-content).
- Local builds are allowed. Use a disposable checkout and its own `out/` directory.
  Do not test against live world data or install a candidate on a live server.
- Run checks appropriate to the change. Docs-only changes need links and documented
  commands checked; toolchain or packaging changes need `./build.sh` and its
  runtime-image checks. Report unavailable checks as unverified.
- `VERSION`, official tags, release assets, and publishing belong to Brian's release
  workflow. Do not bump versions, replace published assets, or dispatch release
  workflows merely to validate a contribution.
