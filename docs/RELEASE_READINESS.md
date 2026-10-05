# Release readiness, 2026-10-04

This audit covers the local `hydronium-templates` candidate and Meteorite checkout. It does not certify the currently published versions or the complete site's Linux deployment.

## Checks completed

| Check | Result |
| --- | --- |
| Hydronium Lua suite | 1,463 passed after the Lab composition changes |
| Generated starter suite | 84 passed |
| JavaScript client suite | 93 passed |
| Vite adapter suite | 20 passed |
| DOM client and Vite vendor drift | No drift |
| Browser primitive checks | Virtual scrolling, listener cleanup and Lab controls passed |
| Packaged islands starter | SSR, JS hydration, actions and navigation passed |
| Packaged SSR starter | Lua-wasm hydration and no-JS progressive actions passed |
| Packaged SSR development | State survives HMR; Tailwind changes apply without page reload |
| Packaged mixed Lab | DOM/Ink controls, HMR and persisted preferences passed |
| Packaged SPA | Counter, greeting, navigation and CSS font asset passed |
| i18n formatters | 1,017 Lua/JS comparisons passed under Lua and LuaJIT |
| Installed package assets | LUAX grammar, i18n compiler and Lua modules load |
| macOS handler relocation | Server responds after moving its runtime files and removing the original absolute handler path |
| Meteorite release assets | Rebased handler is included in the deployment closure |
| Meteorite Lua suite | 37 test files passed |
| Meteorite repository hygiene | Passed |
| Linux aarch64 clean install and relocation | Hybrid server responds after relocation and honours runtime `PORT` |
| Lab composition browser checks | Optional chrome, multiple roots, repeated mounts and cleanup passed |
| Lab pipeline | Freshly installed packages load the component API and emit canonical host/discovery files through Ballad |
| Final packaged Lab gate | DOM/Ink controls, HMR, rulers, editable guides and persisted preferences passed against the fresh export |

The SPA font check uses a real WOFF2 asset. Its emitted filename remains distinct from `site.css`. Candidate registry checks use a fresh store and explicit registry priority so an existing artifact with the same package version cannot conceal missing assets.

## Changes from this audit

- Generated SSR and islands launchers honour `VITE_PORT` and use `--strictPort`, preventing Vite from silently choosing a different port.
- LUAX exports its canonical TextMate grammar as an installed package asset.
- The i18n orbit exports its Lua runtime and JavaScript compiler together.
- Orbit fingerprints include grammar, types and compiler sources.
- Published Ballad 0.4.2 checks orbit inputs on each export, caches the native export task, and resolves absolute input globs from their directory prefix. The real orbit regression verifies unchanged cache reuse plus edited, added and deleted source files without clearing caches. Linux and Windows CI passed. This checkout requires and resolves 0.4.2 for both tool and runtime roles; its package export completed with the existing cache and includes the new Lab component files.
- Meteorite release graphs copy absolute Lua handlers into relative runtime paths. Partition hashes retain the original source path for change detection.
- Meteorite requires a Lua 5.4-compatible `lua-cjson` version.
- Deployment documentation no longer describes unread socket environment variables.
- Regression checks cover opaque JS island hydration and relocated handler packaging.
- Lab exposes its workbench parts as public components, forwards replacement/omission slots through renderer documents, and binds existing ruler/guide layers without inserting missing chrome. Its Ballad plugin delegates to the CLI's canonical planner. See [Lab composition](LAB_COMPOSITION.md).

The template redesign, SPA asset naming, Query observation changes and Lab changes were already present in this checkout. Their passing checks are evidence for the candidate, not changes authored by this audit.

## Remaining release work

1. Build and exercise the complete site on Linux using its actual release closure. A small relocated handler fixture alone does not validate every site asset and dependency. Linux amd64 was not validated; the amd64 emulation environment failed before package checks.
2. Assign new versions to changed packages, resolve the candidate worktree with the main checkout, and run CI against the exact release commits.
3. Publish those new versions, upgrade the site through Moonstone, and repeat the staging smoke checks against the installed artifacts.

The initial Linux image's older Moonstone CLI selected an incompatible CJSON release. A clean run with the current CLI and the raised Meteorite constraint completed installation, compilation and the relocation check.

Ballad 0.4.2 was published during this audit. No Hydronium packages were published and no site deployment was performed.
