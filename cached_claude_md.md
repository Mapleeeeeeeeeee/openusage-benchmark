# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Read AGENTS.md first.** It is the authoritative agent guide and overrides this file on any conflicts.

## What This Is

OpenUsage is a macOS menu bar app (Tauri 2 + React) that tracks AI coding subscription usage across 19+ providers (Claude, Copilot, Cursor, Grok, etc.) via a plugin system.

**Branch/edition split:** `main` = Tauri (`0.6.x`, frozen); `swift` = Swift rewrite (`0.7.x+`, active). Do not merge across editions. Never reuse version numbers across editions.

## Commands

Requires Bun and Rust toolchains.

```sh
bun run dev              # Vite dev server only (port 1420)
bun tauri dev            # Full app (Tauri + frontend)
bun run test             # Vitest
bun run test:watch       # Watch mode
bun run test:coverage    # Coverage (90% threshold enforced)
bun run build            # Type-check + production bundle
bun run bundle:plugins   # Copy plugins to Tauri resources (needed before tauri dev/build)
```

## Architecture

**Frontend** (`src/`): React 19 + TypeScript + Vite + Tailwind CSS 4 + Zustand

Three Zustand stores are the source of truth:
- `app-ui-store` — active view, modal visibility
- `app-plugin-store` — plugin metadata + per-plugin settings
- `app-preferences-store` — user preferences (theme, refresh interval, shortcuts)

Derived values are computed in hooks, not stored. Use `useShallow()` for store subscriptions.

**Backend** (`src-tauri/src/`): Rust + Tauri 2

- `lib.rs` — app init, Tauri command handlers, plugin system setup
- `plugin_engine/` — runs plugin JS bundles via rquickjs (max 4 concurrent workers); results emitted as `probe:result` / `probe:batch-complete` Tauri events
- `local_http_api/` — HTTP server on `127.0.0.1:6736` for external integrations; caches last successful probe output
- `panel.rs` — macOS NSPanel (menu bar popup window)
- `tray.rs` — menu bar icon + tooltip

**Plugins** (`plugins/<name>/`): Each plugin is a `plugin.json` manifest + `plugin.js` bundle. The JS exports an async `probe(ctx)` function that fetches from the provider's API and returns structured metric lines. See `docs/plugins/api.md` for the full plugin API.

**IPC:** JS → Rust uses camelCase (`{ batchId, pluginIds }`); Tauri auto-converts to Rust snake_case. Sending snake_case from JS silently drops params — always use camelCase.

## Key Conventions

**Icons:** Use `@hugeicons-pro/core-solid-rounded` exclusively. Pattern: `<HugeiconsIcon icon={FooIcon} className="size-4" />`. Never pass `strokeWidth`. Replace any `lucide-react` you encounter.

**UI copy:** Titlecase all hardcoded UI strings.

**Error handling:** Fail loudly into error logging (Sentry); show friendly messages to users. No silent fallbacks.

**File size:** Keep files under ~500 LOC; split when needed.

**Plugin PRs:** Audit request/response fields against redaction lists in `src-tauri/src/plugin_engine/host_api.rs`. Set `brandColor` to the provider's real brand color. Plugin SVG logos must use `currentColor`.

**Before any PR:** Update `README.md` plugin list. If there are visual changes, include before/after screenshots.

## Release (Tauri edition)

Tags (`v0.6.x`) cut from `main` trigger `.github/workflows/publish.yml` which builds, signs, notarizes, and uploads DMGs for aarch64 + x86_64. Version must be in sync across `package.json`, `src-tauri/Cargo.toml`, and `src-tauri/tauri.conf.json`. Use the `release-tauri` skill.
