# Contributing

Thanks for helping improve the XENEON EDGE Agent Command Center.

## Before you start

- Open an issue before proposing a large product or architecture change.
- Keep Herdr authoritative, `xeneon-agentd` responsible for normalization and
  actions, and Quickshell presentation-only.
- Never expose prompts, terminal contents, credentials, or raw provider data.
- Preserve fail-closed display and touchscreen identity behavior.
- Keep installation user-owned, reversible, and isolated from packaged
  Omarchy files.

## Development

Install the pinned tools and run the complete local gate:

```bash
mise install
mise exec -- just check
```

Use `mise run preview` for deterministic UI work. Hardware-facing changes must
also distinguish fixture validation from physical XENEON testing.

## Pull requests

- Keep each pull request focused and explain its user-visible impact.
- Add or update focused tests for behavior changes.
- Include the commands and environments used for verification.
- Call out skipped physical, accessibility, or runtime checks explicitly.
- Do not include local commissioning files or hardware identifiers.

By contributing, you agree that your contributions will be licensed under the
project's [MIT License](LICENSE).
