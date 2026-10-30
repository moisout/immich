# AGENTS.md

Immich monorepo; this fork only changes the mobile app: `mobile/` (Flutter) and `native/` (Rust core for mobile). See `FORK.md` for the fork's changes. Before changing code in `mobile/` or `native/`, read that folder's `AGENTS.md`.

## Rules

- Run every build, lint, test and codegen task through mise: `mise //<dir>:<task>`, root tasks as `mise //:<task>`. `mise tasks ls --all` lists them.
- Never hand-edit generated files: `mobile/generated/openapi/` and Dart codegen (`*.g.dart`, `*.drift.dart`, `*.freezed.dart`, `router.gr.dart`, `lib/generated/`, `lib/platform/*.g.dart`).
- Only edit `i18n/en.json`; the other locale files come from Weblate.

## Skills

- **Add a translation string**: add the key to `i18n/en.json`, then run `mise //:i18n:format-fix` so the file stays key-sorted, and `mise //mobile:translation`.
