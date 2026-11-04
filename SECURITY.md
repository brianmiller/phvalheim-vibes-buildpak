# Reporting vulnerabilities

Do not post vulnerability details, credentials, or exploit instructions in public
issues, PRs, or Discord. The Build Pak is consumed by PhValheim Server. Report
suspected Build Pak vulnerabilities privately through
[PhValheim Server's vulnerability reporting form](https://github.com/brianmiller/phvalheim-server/security/advisories/new)
and identify `phvalheim-vibes-buildpak` as the affected component.

Include the affected pak version/commit, component, impact, and a sanitized
reproduction. Do not attach game assemblies or player data. If you cannot access
the private form, arrange a private reporting channel with Brian before sending
the details; do not fall back to a public issue.

The build workflow's vulnerability scan currently produces a non-blocking report.
A successful build does not mean that report is empty. Brian decides remediation
and release timing; contributors must not publish a security fix or release without
his approval.
