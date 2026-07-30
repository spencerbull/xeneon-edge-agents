# CI and private package releases

The repository uses GitHub Actions for source verification and private Arch
package artifacts. It does not publish to the AUR.

## Source CI

`.github/workflows/ci.yml` runs on every branch push, pull request, and manual
dispatch, and can be called as the tag release gate. Its single job runs inside
the official Arch Linux `base-devel` container and:

1. installs the project's Rust, Qt/QML, Lua, Python, and shell test tools;
2. restores Cargo registry and build caches keyed by the Rust toolchain and
   `Cargo.lock`;
3. runs ShellCheck over shell files under `scripts/`, `tests/`, and
   `packaging/arch/`, using the shebang rather than executable mode so Python
   helpers are not misclassified, with documented exclusions for
   shared-library exports, the tested quote pattern, and a signal callback
   referenced indirectly by `trap`; and
4. runs `just check`, the same formatting, Clippy, Rust test, QML test,
   installer test, and whitespace gate used locally.

The job has read-only repository permissions, a 35-minute timeout, and cancels
an older run for the same branch or pull request.

## Unpublished Arch package workflow

`.github/workflows/package.yml` runs when manually dispatched and on every
branch push, pull request, and `v*` tag. Running broadly ensures that changes
to Rust, QML, scripts, templates, documentation, or packaging all exercise the
archive path. It expects the package definition at `packaging/arch/PKGBUILD`;
until that file is present, it exits with an explicit error.
Superseded branch and pull-request builds are cancelled, while tag builds are
never cancelled automatically.
Tag builds call the source workflow first and cannot build or release unless
the complete source gate succeeds. Branch and pull-request package builds rely
on the independently triggered source workflow to avoid running that same
gate twice.

The workflow installs a short, root-owned allowlist of build and audit tools
before any package code runs. It then runs `makepkg --nodeps` as an
unprivileged `builder` user with no `sudo` access. Keep the build portion of
that workflow allowlist synchronized with the `PKGBUILD` `makedepends`; this
avoids granting a checked-out `PKGBUILD` passwordless package-manager access.
The authoritative `packaging/arch/build-local-package` helper creates a clean
archive from the checked-out commit, injects its checksum into a private
PKGBUILD, and runs `makepkg --nodeps`. Each run produces:

- exactly one binary package;
- exactly one `makepkg --source` source package;
- a generated `.SRCINFO`;
- the `namcap` report and complete binary-package file list; and
- `SHA256SUMS` covering all of those files.

`namcap` errors fail the build while warnings remain visible in the report.
The archive inspection also rejects any payload outside the package's narrow
`/usr` ownership contract, including all home/XDG paths and
`/usr/share/omarchy`.

These files are stored as a private Actions artifact for 14 days. GitHub does
not give releases a visibility setting separate from their repository, so the
tag job verifies through the GitHub API that the repository is still private
before creating a release. If a release already exists, this workflow refuses
to replace it or any asset. The workflow uploads every asset to a draft and
publishes it only after all uploads succeed.

Repository-level immutable releases are a separate administrator setting and
are currently a human gate: without that setting, an administrator can still
alter a release outside this workflow. The release job reports that state.
Enable immutable releases before treating these artifacts as permanently
locked.

The package version must match the one shared by all Cargo workspace packages.
For a tag release, the tag must exactly equal `v` followed by that source and
package version, for example `v0.1.0`, and the tagged commit must be contained
in the repository's default branch. Create and push a tag only after CI passes:

```bash
git tag -a v0.1.0 -m "XENEON EDGE Agents v0.1.0"
git push origin v0.1.0
```

This creates an annotated tag. Signing is optional and is not verified by the
current workflow. The release job resolves the remote tag before draft
creation and immediately before publication, but protected tag rules remain
the administrator control that prevents force-moves outside the workflow.

A manual package-only smoke test can be requested with:

```bash
gh workflow run package.yml
gh run watch
```

No AUR credentials, signing keys, package registries, or repository secrets
are used. The release job uses only its short-lived `GITHUB_TOKEN` with
`contents: write`; all other jobs have `contents: read`. SHA-256 checksums
detect transfer corruption but do not replace package signatures. Signing can
be added later through an explicitly approved secret-management design.

Pull-request package builds run every validation gate but deliberately do not
upload installable artifacts. Their package payload is controlled by the pull
request and must not be treated as trusted before review.

All reusable actions are pinned to immutable commit SHAs. Dependabot checks
those action pins weekly. Repository administrators should require the
`Source gates (Arch Linux)` check on the default branch and keep the Actions
workflow permission setting capable of granting the tag release job
`contents: write`.

The jobs pin the official `archlinux:base-devel` container to an immutable
digest and then perform a full `pacman -Syu`, matching an up-to-date
Omarchy/Arch target. Arch repository updates can still change the resolved
packages without a repository commit. Dependabot does not maintain container
digests in workflow `container.image` fields, so refresh this digest through an
intentional pull request and rerun both workflow gates.
