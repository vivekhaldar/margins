# Margins — Agent Instructions

## Required Pre-Completion Check

Run this before finishing any task:

```sh
scripts/check.sh --diff
```

For a full repository check (also enforced in CI):

```sh
scripts/check.sh --all
```

On macOS 14+ (Swift 5.10+), `scripts/check.sh` runs `scripts/slop-check.py`, `swift build`, `swift run MarginsSelfTest`, `node scripts/test-annotation-alignment.js`, and optional local linters (`swiftlint`, `eslint`). On Linux agent containers (`.agents/setup`), Swift steps are skipped automatically while `slop-check.py` and the Node alignment tests still run.

## Architecture & Domain-Extension Layout

Keep large coordinators split by cohesive domain extensions rather than growing monolithic files:

- **`AppState` (`Sources/Margins/`)**
  - `AppState.swift` — core `@Observable` state, initialization, zoom, preferences
  - `AppState+Providers.swift` — model provider discovery, selection, and configuration
  - `AppState+Project.swift` — project folder, git status, and workspace metadata
  - `AppState+Files.swift` — file loading, saving, external reload, and document switching
  - `AppState+Agent.swift` — agent turns, selection threads, diffs, and review actions
- **`SyncEngine` (`Sources/MarginsCore/Sync/`)**
  - `SyncEngine.swift` — sync lifecycle, scheduling, state, and error handling
  - `SyncEngine+Reconciliation.swift` — pull/push reconciliation, conflict handling, change coalescing
  - `SyncEngine+Files.swift` — local file I/O and Markdown serialization helpers
- **Embedded editor (`Sources/Margins/Resources/Editor/`)**
  - Loaded via `<script>` tags in `editor.html` (`annotations.js`, `tracked-diff.js`, `editor.js`, `annotations-ui.js`) with zero npm runtime dependencies. Keep them plain browser scripts.

## Structural Guardrails

- Keep production files under **500 LOC** and functions under **80 LOC** (existing legacy files/functions are ratcheted at their current size in `scripts/slop-check.py` and must not grow).
- Decompose complex functions before exceeding cyclomatic complexity or nesting limits (`.swiftlint.yml`, `eslint.config.mjs`).
- Never leave empty `catch` blocks in editor scripts — log or handle errors explicitly.
- Do not leave stray `print(` / `debugPrint(` in `Sources/Margins` or `Sources/MarginsCore`, or `console.log` / `debugger` in `Sources/Margins/Resources/Editor/*.js`.

## Optional Local Git Hook

Enable the fast (< 2s) staged pre-commit check locally with:

```sh
git config core.hooksPath .githooks
```
