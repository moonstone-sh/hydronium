# Ecosystem boundaries: Ballad, Meteorite, Hydronium, Vite, Lab

Who owns which part of a Hydronium application, the order its pipelines run
in, and what is still open. Written 2026-09-29; every "verified" claim below
lists the command or browser run that checked it (see the ledger at the end).

## Ownership

| Layer | Owns | Knows nothing about |
| --- | --- | --- |
| **Ballad** (`moonstone/ballad`) | Build graph engine: assets, caching, plugins, sinks, registry packaging | Hydronium, LUAX, Meteorite (`ballad/src` has zero references) |
| **Meteorite** (`moonstone/meteorite`) | HTTP: routes, handlers, static files, dev server/rebuilds, the compiled server binary, typed DTO clients | Hydronium, LUAX (`meteorite/src`, `zig/` have zero references) |
| **Hydronium Ballad plugins** (`hydronium/ballad`, `build/`) | `.luax` → Lua, source topology, client resolve/minify/bundle, scoped CSS, hashed assets, Vite dist ingest, the merged `dist/` manifest | Meteorite |
| **Hydronium ↔ Meteorite adapters** | `hydronium_dom.server.meteorite` (render, `mount`, `dev_watch`) and `hydronium_router.meteorite` (pages/actions → routes) | -- |
| **`hydronium dev`** (`hydronium/cli`) | Dev orchestration: supervises `meteorite dev` (and `vite dev`), status UI | Build internals |
| **Vite** | JS islands, npm/TS deps, Tailwind/PostCSS, their own HMR | Lua (never sees a `.lua`/`.luax` module) |
| **Lab** (`hydronium/lab`, `lab-cli`, `ink-lab`, `hydronium/meteorite`) | Story discovery, workbench, isolated preview processes | Application routes |

The integration code lives on the Hydronium side on purpose. Ballad and
Meteorite stay general-purpose; Hydronium adapts to them.

## Production build

```
hydronium.sources.lua ─► topology.classify ─► luax.compile ─► client.resolve ─► client.minify ─► client.bundle ─┐
  (module topology)       (ids, targets)      (.luax→Lua,     (module-level      ("safe":           (one package_ │
                                               refresh pass)   tree shaking)      whitespace only)   preload chunk)│
                                                                                                                 ▼
src/**/*.css ─► style.bundle ─────────────────────────────────────────────────────────────────────────► site.manifest ─► dist/
public/* ─────► assets.hash ──────────────────────────────────────────────────────────────────────────►   (.lua + .json)
Vite dist/ ───► vite_assets.ingest ───────────────────────────────────────────────────────────────────►
```

- **Tree shaking happens at the module level only.** `client.resolve` emits
  only modules reachable from the declared entries, and a require-discipline
  lint makes that walk provably complete. There is no tree shaking inside a
  module: Lua's dynamic `require`/`package.loaded` makes it unsound.
- **Vite is a side input, not the last stage.** Vite cannot package Lua into
  a `package.preload` chunk, and making it the final step would force Node onto
  Lua-only apps. `vite_assets` passes through unchanged when no Vite build exists.
- **`dist/` does not depend on the server.** Meteorite is the default host
  (`meteorite.site`, `m.dir`), and the SPA mode ships the same output with no
  Meteorite at all.

## Development

App code is never bundled in dev. Bundling on every save would work against
HMR's per-module state preservation (`HYDRONIUM_DEV_HMR_ROADMAP.md`, "The
architectural question, resolved").

- **Discovery is a Ballad node.** `partiture.lua` calls
  `hydronium_ballad.source_inventory(p)`, which scans the roots declared in
  `hydronium.sources.lua` and writes `.hydronium/ballad/source-inventory.lua`.
  `hydronium dev --watch-sources` re-runs it when a `.lua`/`.luax` file appears
  or disappears under a root, or when that file changes (about 0.15s per run).
  `moon run build` runs it before compiling the server.
- `/__hydronium/dev/module/:id` compiles one declared module on demand.
- `/hydronium-src/*` plus `/__hydronium/client_manifest.json` serve the
  framework unbundled. The manifest is derived from the app's real `require`
  graph, walked by `hydronium.core.require_scan`, the same scanner Ballad's
  `client.resolve` bundles with.
- `/__hydronium/watch` streams changes. The `updates` policy for each file
  (`hot`, `reload`, `style`) comes from `hydronium.sources.lua`, including
  stylesheets declared as `watch = { { path, href } }`, which `mount()` serves
  from disk at their own URL during development.
- `hydronium.dev_watch()` marks `hot` modules and those stylesheets as passive
  Meteorite inputs, so editing them never restarts the server.
- `hydronium dev` supervises `meteorite dev`. In the `ssr` template it also
  runs `vite dev` for CSS (two HMR systems, deliberately uncoordinated:
  `HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md` §2.4). Vite's only Lua-related job is
  `scripts/lua-hot-update.mjs`, which stops it from full-reloading on Lua edits.
- **Release builds** (Meteorite `release-*` modes) drop the HMR stream and
  the from-disk stylesheet routes, and the module manifest reports
  `hmr: false`, so the page skips `installHmr`.
- **Production bundle.** `moon run build` runs `build.partiture.lua`:
  `hydronium_ballad.client_bundle(p)` compiles every client/shared module
  declared in `hydronium.sources.lua`, walks from all of them (router screens
  are named by string, so "reachable from the root" is not enough), includes
  only the framework modules they and `mount.js` reach, minifies ("safe"), and
  writes one content-hashed chunk to `.hydronium/client/`. In release builds
  `mount()` serves it immutable at `/__hydronium/client/*`, and the module
  manifest lists it as `chunks`, so the page boots with `chunkUrls`: one
  request instead of one per module. Server-target modules (the document)
  stay out of the chunk. Without a bundle, release pages fall back to
  per-module delivery; development never uses the bundle.

## The SSR surface: three kinds of routes

Meteorite owns HTTP, and an app's `src/main.lua` is an ordinary Meteorite app:

```lua
local hydronium = require("hydronium_dom.server.meteorite")
local router = require("hydronium_router.meteorite")
local app = meteorite.app({ name = "app", port = 8080, dev_watch = hydronium.dev_watch() })

hydronium.mount(app)                               -- 1. framework routes
router.mount(app, site, { handler = ..., action_handler = ... }) -- 2. pages + actions
app:get("/hello/:name", { summary = "Greeting" },   -- 3. your routes
  meteorite.lua("app.hello", { arg_mode = "lazy_context" }))
```

A route handler renders any component with
`dom.render(c, Component, { props = ... })`. Components live wherever the Lua
path reaches: `examples/quickstart` and the `ssr` template render
`src/features/greeting/Greeting.luax`.

Handlers are separate modules (`meteorite.lua(...)`) because Meteorite's
hybrid build loads each handler standalone and rejects inline handlers that
capture outer locals. `mount` uses the same mechanism: its Lua routes are `m.lua`
file handlers shipped inside `hydronium/dom`
(`hydronium_dom/server/meteorite_routes/`). That is why a library can own
them and they no longer have to be copied into every app. Before this, quickstart's copy
of these routes had drifted to a captured-local build failure, and its pasted
framework manifest was missing `hydronium.core.module_graph`.

### Why Meteorite is exposed, not hidden

- App authors write Meteorite code (routes, APIs, DTO clients), so hiding it
  would only rename it.
- It carries a Zig toolchain. SPA mode needs no server at all, so it stays an
  optional peer, not a hidden dependency of `hydronium/core`/`dom`.
- What *is* hidden is operating it: `hydronium dev` spawns and supervises
  `meteorite dev`, and `mount`/`dev_watch` hide the framework routes and
  watch policy.

## Lab

Lab is where it should be: a separate dev tool process. `hydronium-lab dev`
generates `.hydronium/lab/main.lua`, a Meteorite app that calls
`lab.mount(app, ...)` on its own port (6100). That is the same "Meteorite
owns HTTP, a Hydronium adapter mounts routes" shape an application uses.
Stories are ordinary Lua/LUAX modules.

Aligned with the app (2026-09-29):

- Project module ids resolve through the app's own source topology first
  (`hydronium_dom.dev.source_registry.load_project`: Ballad inventory, then
  `hydronium.sources.lua`), in both the DOM preview bundler and the Lua
  searcher Ink stories load through. So namespaced roots like
  `{ path = "src/components", namespace = "ui" }` work in Lab exactly as in the
  app. `hydronium.lab.lua`'s `module_roots` remains the fallback for projects
  without a topology; its `roots` still say where stories live, which is a Lab
  concern.
- The DOM preview walks requires with `hydronium.core.require_scan`, the same
  comment- and string-aware scanner Ballad bundles with.
- The DOM client runtime is served by structure (any `.js` at the root of
  `hydronium_dom/client/`, plus the vendored wasmoon files), not a hand-kept
  list. Traversal and other paths are refused.

Still open: `hydronium/meteorite` is Lab's host adapter, but its name reads as
the application integration (see gap 1).

## Known gaps, in priority order

1. **Rename `hydronium/meteorite`, for clarity.** It is Lab's host adapter,
   but its name reads as the application integration (which is
   `hydronium_dom.server.meteorite`). It no longer breaks anything (see
   "Install paths" below), so this is purely about naming; ship it in the next
   deliberately breaking release. Keep `hydronium/ballad`.

### Install paths (Moonstone 0.5.9)

Moonstone mounts each package at `.moonstone/env/libexec/<namespace>/<name>`
(`moonstone/meteorite` at `libexec/moonstone/meteorite`). The old flat
`libexec/<name>` survives only as an alias when exactly one package claims it.
Before 0.5.9 same-named packages silently replaced each other
(`hydronium/ballad` vs `moonstone/ballad`, `hydronium/meteorite` vs
`moonstone/meteorite`), and the winner varied by project. A contested flat name
is now absent and listed under `[[libexec_alias_conflict]]` in
`.moonstone/env/env.toml`.

- Generated `build.zig` files import
  `libexec/moonstone/meteorite/meteorite/zig/build_api.zig`, so the `ssr`,
  `spa` and `islands` templates need Moonstone 0.5.9+. An app that also
  installs Lab (`hydronium/meteorite`) now builds by construction; it was
  verified with both packages present.
- `mount()` looks for the DOM and router browser assets under the namespaced
  paths first and the flat aliases second, so it works on either Moonstone.
- Paths no other package shares (`libexec/luajit`, `libexec/luax/types`,
  `libexec/dom/types`) keep their flat alias and are unchanged.
- Meteorite finds its own package under either path
  (`src/cli/package_context.lua`), and its `meteorite init` template now
  imports the namespaced path. The previous `libexec/meteorite/files/meteorite`
  path did not exist on current installs.

Resolved 2026-09-29 (details in the ledger):
- Same-named packages shadowing each other on install (namespaced `libexec/`
  in Moonstone 0.5.9).
- Vite-owned discovery (now Ballad).
- The quickstart CSS rebuild race (stylesheets served from disk in dev).
- Duplicate require-graph walkers (all on `hydronium.core.require_scan`, Lab included).
- Dev routes in release binaries.
- Undecoded Meteorite path params.
- Production module delivery (now one Ballad chunk).
- Lab's separate source declaration and hand-kept client list.
- The Meteorite `web-standards` crash. The server compiled against the
  project's Lua 5.4 headers but linked `-llua`, which resolved to Homebrew's
  `liblua.5.5.dylib`, so native modules like `cjson` crashed. Meteorite now
  links the project's archive by path. Hydronium apps' `build` scripts also
  never passed `--lua-root`, so their release servers had been running on
  that system Lua instead of LuaJIT.

## Verification ledger (2026-09-29)

- `moon exec -- luajit tests/runner.lua`: 1402/1402 (1390 before; new specs
  cover `mount`, `dev_watch`, `client_manifest`, `<title>` markers, and the
  CLI's child `LUA_PATH`).
- `create`: `moon run test`, 74/74.
- `examples/quickstart` on registry Meteorite 0.3.1: the `hybrid_dev` graph
  builds (it failed before this change), every mounted route answers, and the
  `release-hybrid` binary serves the same routes. A Playwright run covered:
  hydrate, two clicks, a `.luax` edit hot-swapped with state kept, the next
  click uses the new code, no reload, and no console errors or failed requests.
- A freshly scaffolded `ssr` app (Hydronium deps pointed at this checkout),
  run through its own `pnpm run dev` → `hydronium dev` → Meteorite + Vite:
  the same Playwright scenario, plus `/hello/Ada` rendering with a clean `<title>`.
- Found and fixed along the way: SSR text markers inside `<title>`/`<textarea>`
  (they rendered as literal text), and `hydronium dev` leaking the CLI's
  bundled Hydronium copy into the app's Meteorite graph via `LUA_PATH`.

Second pass (same day):

- Root suite 1415/1415, `create` 74/74, Meteorite Lua suite 34/34, plus a new
  Zig unit test for capture decoding.
- Ballad discovery on a fresh `ssr` scaffold via `pnpm run dev`: no
  `.hydronium/sources.lua` is written; a new component is served about 1s
  after creation and returns 404 after deletion; the Playwright HMR scenario passes.
- The same scaffold's release build (`pnpm build`, then `moon run build`):
  pages render, `/__hydronium/watch` is 404, the manifest reports `hmr: false`,
  and in the browser the page hydrates and clicks with zero watch requests and
  no errors.
- Quickstart CSS: a `public/style.css` edit applies in about 0.5s with no
  reload, counter state kept, and the same server PID (no rebuild).
- Meteorite 0.3.2 (checkout): `/params/lua-text/Ada%20Lovelace` yields
  `Ada Lovelace` through both `c:param()` and `c.params`; the static routes still
  reject `%2e%2e` and `%2f` (404). Checked on a port-isolated build of the
  `web-standards` fixture, whose own script kills anything listening on :8080.

Third pass (same day):

- Root suite 1423/1423, `create` 74/74, Meteorite Lua suite 34/34, and the full
  `web-standards` fixture passes end to end for the first time (it crashed
  before). Run on a port-isolated copy of its script, because the original
  kills anything on :8080.
- Release binaries built with Meteorite 0.3.2 link only `libSystem`; the Lua
  API is exported for native modules (343 symbols for PUC Lua), and quickstart's
  server now embeds LuaJIT.
- Production bundle on a fresh `ssr` scaffold and on quickstart: one
  immutable, content-hashed chunk (65 modules, 227KB for the scaffold, with
  `views.Document` and `hydronium_dom.server` excluded). In the browser: zero
  per-module or `/hydronium-src` requests, zero HMR requests, the counter works,
  client-side navigation works, no errors. Dev HMR and the CSS swap re-verified.
- Lab: a namespaced `ui.Button` import resolves through `hydronium.sources.lua`
  in the DOM preview bundler (new spec).

Fourth pass (same day), Moonstone namespaced `libexec/`:

- Moonstone: 340/340 unit tests (including two new `mountLibexec` tests) and its fast
  tier (format, unit, contracts). A real sync of a project with both
  Meteorite packages yields `libexec/moonstone/meteorite`,
  `libexec/hydronium/meteorite` and no flat `meteorite`, and records the conflict
  in `env.toml`. A use-after-free in the first cut (a flat name that pointed
  into a freed buffer, which surfaced as `BadPathName`) was found on that real
  sync and fixed. The unit tests had used static strings.
- Moonstone's synthetic end-to-end tier: 56 suites pass on 0.5.9, including
  the projection suites. 15 fail identically on the unmodified 0.5.8 baseline
  (a separate build, same suite, same sandbox), so they predate this change:
  packages missing from the synthetic sandbox registry ("package not found").
  One suite hung for over 30 minutes in `moon interpreter set lua@5.4.6` and
  was stopped. Both need their own investigation.
- Meteorite: a new `tests/package_context.lua` (namespaced-only and flat-only
  environments) and `tests/build-api-native.sh` pass.
- A fresh `ssr` app that also installs `hydronium/meteorite`: sync, release
  build (`otool -L`: `libSystem` only), pages render, and the bundle chunk is served.
- Your other projects: only a shared flat name disappears, and none of them
  reference one. pepes23 and coso import `libexec/meteorite` but have only
  `moonstone/meteorite`, so their alias remains.
