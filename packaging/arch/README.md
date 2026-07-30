# Local Arch package

This directory builds an unpublished, local-only Arch package. It is suitable
for installing and exercising the package lifecycle on this Omarchy host, but
it is intentionally **not AUR-ready**.

## Build

Commit the intended snapshot, then run:

```bash
packaging/arch/build-local-package
```

CI runners whose package dependencies were provisioned separately use
`packaging/arch/build-local-package --nodeps`; this skips only pacman dependency
resolution, not compilation, tests, package validation, or source checks.

The helper creates a deterministic `git archive` from `HEAD`, injects that
archive's SHA-256 into a private copy of `PKGBUILD`, runs `makepkg` without
installing anything, validates the binary and source packages, and writes:

- `packaging/arch/dist/xeneon-edge-agents-0.1.0-1-x86_64.pkg.tar.zst`
- `packaging/arch/dist/xeneon-edge-agents-0.1.0-1.src.tar.gz`
- `packaging/arch/dist/.SRCINFO` with the effective local source checksum

Build prerequisites are `base-devel`, Rust/Cargo, Git, and gzip. Runtime
dependencies are declared in `PKGBUILD`; Herdr remains optional package
metadata because this private host installs it in `~/.local/bin`.

The build helper never runs `pacman`, never installs the resulting package, and
refuses dirty or non-HEAD sources.

## Package lifecycle

The package owns only `/usr` payload:

- Rust binaries and command links in `/usr/bin`
- disabled user-level units in `/usr/lib/systemd/user`
- lifecycle helpers in `/usr/lib/xeneon-edge-agents`
- QML, templates, and schema in `/usr/share/xeneon-edge-agents`

Package installation alone does not write to a home directory and does not
enable either service. After a local `pacman -U` test, the user-facing command
is:

```bash
xeneon-edge-agents install
xeneon-edge-agents check
xeneon-edge-agents detect
xeneon-edge-agents preview
xeneon-edge-agents migrate
xeneon-edge-agents uninstall
```

Long-form compatibility commands such as
`xeneon-edge-agents-install` and `xeneon-edge-agents-check` are also installed.

The default `install` is simulator-safe. It seeds only user commissioning
files, migrates unchanged manifest-owned legacy units, QML copies, and
repository-launch helpers to static package assets, and leaves the user
services stopped and disabled. Migrating an unchanged legacy unit stops and
disables that legacy service; rerun with the complete production identity and
`--activate` to start the package unit. Modified legacy static files are
preserved; a modified user service override blocks migration because it would
mask the packaged unit.

Production remains explicit and uses the same complete
`--apply-production ...` identity arguments documented in the project
commissioning guide. `--activate` is the only path that enables services. It
requires exact live display/touch identity, a compatible running Herdr socket
protocol, clean Hyprland validation, and an exact validated portal environment.

## Publication gate

Do not upload the current `PKGBUILD` or placeholder-generated `.SRCINFO` to the
AUR. Publication requires a separate review that:

1. creates an immutable public release/tag and source archive;
2. replaces the local archive in `source=()` with its public HTTPS URL;
3. commits the immutable source checksum and regenerated `.SRCINFO`;
4. replaces the private snapshot notice with a reviewed project license;
5. verifies dependency names and clean-chroot reproducibility; and
6. reruns physical XENEON commissioning and touch validation.
