# Capture-only fork

The user explicitly requested this fork and its separate public API. This is
not an upstream PostHog contribution or an official SDK release. Upstream's
issue-agreement and maintainer-release workflows apply only when contributing
or publishing upstream; do not open issues or publish upstream packages here.

Keep upstream Swift files unchanged. Admit files through `package-sources.json`;
new upstream files must never enter the product implicitly. Put fork behavior,
tests and documentation under `LakeOfFire/`. Regenerate root manifests from
`Package.template.swift` with `scripts/render-manifests.py`.

Use `make -f LakeOfFire/Makefile test`, `build`, and `audit` for this package.
The old root Makefile and Xcode project describe the full upstream SDK and are
retained for merge history, not as supported fork distribution entrypoints.
Test real queue/storage/HTTP behavior. Do not run tests against live PostHog.
Use signed commits. Do not merge or publish changes to upstream PostHog.
