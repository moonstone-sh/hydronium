# `@hydronium-js/vite`: the web-asset adapter plan

**Scope:** bring real JS/TS/CSS tooling (Vite 8 + Tailwind v4) to Hydronium DOM apps, as a first-party adapter, without touching the Lua bundling pipeline `hydronium_ballad` already owns.

**Method:** written to this workspace's own standard (`CLAUDE.md`, "Trust issue in `docs/`"). Every claim below is either backed by a command actually run read-only against this tree and the live npm registry on 2026-09-22, or is explicitly labeled **[UNVERIFIED]**. Nothing here is self-certified as working; the milestones define their own falsifiable gates.

**Companion docs:** `HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md` (the Lua bundler this plan deliberately does not change), `HYDRONIUM_DEV_HMR_ROADMAP.md` (the Lua-side HMR roadmap this plan partially retires — see §2.4), `HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md`, `LUAX_BALLAD_CSS_ASSETS_PLAN.md`.

---

## 0. Verification ledger

Established by real commands this session, not from memory:

| Claim | How verified | Result |
|---|---|---|
| Vite 8 **is** Rolldown-powered | `npm view vite@8.3.0 dependencies` | **True.** `rolldown: ~1.2.6`, plus `postcss: ^8.5.28`, `lightningcss: ^1.33.0` as direct deps. The `rolldown-vite` alias package (7.3.1) was the Vite 7 opt-in and is **not needed** |
| Current versions | `npm view` | `vite@8.3.0`, `tailwindcss@4.3.3`, `@tailwindcss/vite@4.3.3` |
| Tailwind is NOT bundled with Vite | dependency list above | **True.** It is a separate first-party plugin install — one `vite.config` line, but not OOTB |
| Toolchain present | `node -v`, `bun -v`, `npm -v`, `pnpm -v` | node 24.14.1, bun 1.4.2, npm 11.11.0, pnpm 11.17.0. Vite 8 needs `^20.19.0 \|\| >=22.12.0` — satisfied |
| npm registry reachable | `npm view vite version` | Yes |
| **Playwright is NOT installed** | `command -v playwright`, `find` for playwright dirs | **Absent.** The "verified live in Chromium" proofs in the ballad docs were ad-hoc installs. M0 must install it or milestones lose their gates |
| A real JS test convention already exists | `ls tests/client/`, `head tests/client/hmr_policy.test.mjs` | **9 `*.test.mjs` files**, `node:test` + `node:assert/strict`. Invoked as `node --test tests/client/<file>` (`ink-lab/README.md:12`). **Corrected 2026-09-22 during M0:** only **5** of the 9 import from `dom/src/hydronium_dom/client/*.js` (`dev_transport`, `forms`, `raw_html`, `hmr_policy`, `boundary_registry`); the other 4 import from `router/client/`, `ink-lab/`, and `lab/` and are unaffected by the client-JS move. The original "9 import from client/" phrasing in this ledger was imprecise |
| CI does **not** run those .mjs tests | `.github/workflows/ci.yml` | CI runs only `moon exec -- luajit tests/runner.lua` then `ballad play partiture.lua`. No node/npm step exists in CI at all |
| `bun:test` already used in this repo | `build/tests/web-build.test.ts` | One TS test file against `build/web/{site-build,pwa,static-export}.ts`. Unrelated to bundling (static export + PWA manifest), but establishes Bun as already-accepted here |
| Client JS surface to move | `ls dom/src/hydronium_dom/client/` | 9 files (`mount`, `dom_bridge`, `bootstrap`, `hmr`, `dev_transport`, `dev_reload`, `priority`, `boundary_registry`, `forms`) + `vendor/` (432K vendored wasmoon) |
| `hy_asset_ref` is designed but unimplemented | grep across `build/src` | Specified in `HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md:217,250`; **zero** occurrences in real plugin source |
| `raw_props.module` passthrough | `dom/src/hydronium_dom/server/init.lua` | Island module specifier is passed through with no URL resolution — the exact seam M2 must change |
| Meteorite cannot serve websockets | `meteorite/src/core/app.lua` | Errors `unsupported_websocket` deliberately. Vite's HMR socket **must** be same-origin to Vite |

---

## 1. Decisions taken (2026-09-22)

1. **In-repo, not a sibling repo.** The adapter consumes `dom/`'s client JS and the explicitly-provisional `client_plan` **v1** contract at internal-API depth. Same reasoning that moved `create` into this repo.
2. **Two packages:** `@hydronium-js/dom-client` (the runtime: mount, bridge, HMR client, islands bootstrap) and `@hydronium-js/vite` (the build/dev adapter). Split because `dom-client` must keep working with **no bundler at all** — a bare `<script type="module">` — which `bootstrap.js`'s own header claims today; folding the plugin in would force a `vite` dependency on every consumer.
3. **Ship M0–M3**, through the production manifest merge.
4. **Move the client JS now**, with a drift check.

**One flagged deviation.** `hydronium/build/web/*.ts` already exists (static-export/PWA scripts inside the ballad plugin package). A new top-level `hydronium/web/` would collide with it in exactly the way `hydronium/ballad/` collided with the sibling `ballad/` repo — which this workspace already resolved by renaming to `build/`. **This plan therefore uses `hydronium/js/`.** If you prefer `web/` anyway, it is a directory rename and nothing else.

---

## 2. The boundary

### 2.1 The cut is by reachability, not by filetype

- **Authored inside `.luax` → `hydronium_ballad` owns it, always.** Including the component's own CSS class scoping: `scope_class` (e.g. `hy-App-1a2b`) is minted by `luax.compile`, the only step that sees component boundaries, and is a **hard invariant** that must survive every later pass untouched (`HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md:248`).
- **Reachable by `import` from a JS/TS entry → Vite owns it, always.** JS islands (`interpreter: "js"`), their npm/TS dependencies, and any `.css` those import.

A `.css` file is not automatically Vite's; a `.css` file *imported by an island* is.

### 2.2 What each side keeps

| Concern | Owner |
|---|---|
| `.luax` → Lua, `scope_class` minting | `hydronium_ballad.plugins.luax` |
| Lua module graph, chunking, `package_preload_v1`, safe minify | `hydronium_ballad.plugins.client` |
| Component-scoped CSS naming, `hy_asset_ref` | `hydronium_ballad.plugins.{style,assets,luax}` |
| Final merged `dist/` manifest | `hydronium_ballad.plugins.site` (**unchanged** — see §4.3) |
| JS islands + their npm/TS deps | Vite 8 / Rolldown |
| Tailwind v4, PostCSS, Lightning CSS | Vite (`@tailwindcss/vite`) |
| Dev HMR socket, error overlay, file watching for JS/CSS | Vite dev server |
| Production JS/CSS code-split, tree-shake, hashed assets | Vite build |

### 2.3 Why the Lua side keeps its own bundler

Not inertia — two independent reasons. Lua's dynamic `package.loaded`/`require` surface makes identifier renaming and intra-module tree-shaking unsound in ways a JS bundler would not know to avoid; and Vite has no concept of amalgamating source into a `package.preload` table for a WASM Lua VM. Note the Lua side already does real **module-level** tree-shaking (`client.resolve()` only emits what is reachable from declared entries), and as of this session that walk is guarded by an enforced require-discipline lint — see `build/src/hydronium_ballad/plugins/client.lua` and `tests/build/client_require_discipline_spec.lua`.

### 2.4 Two HMR systems, deliberately uncoordinated

Lua component state preservation keeps its existing SSE channel (`family_loader.reload()`); JS islands use Vite's native `import.meta.hot`. They own disjoint parts of the module graph and never need to talk. Adopting Vite retires the JS half of `HYDRONIUM_DEV_HMR_ROADMAP.md`'s M2/M4/M5 (client HMR runtime, sub-150ms latency, error overlay) — **for JS/CSS only**. The Lua-side items in that roadmap, especially **M1 (automatic state preservation via a `.luax` compiler pass)**, are untouched by this plan and remain the highest-leverage Lua-side work.

### 2.5 Dev topology: two processes, forced

Meteorite deliberately cannot serve websockets, so Vite's HMR socket must reach Vite's own origin directly. Meteorite serves SSR + API on its port; Vite serves JS/CSS on its own (default 5173) with `server.cors` enabled; SSR HTML references Vite's origin in dev. This is the standard non-middleware Vite integration pattern. **In production Vite does not run at all** — M3's gate asserts exactly that.

---

## 3. Layout

```
hydronium/js/                         # npm workspace root (pnpm or bun), NOT a moonstone package
  package.json                        # private: true, workspaces: ["packages/*"]
  packages/
    dom-client/                       # "@hydronium-js/dom-client"
      package.json                    # dep: wasmoon (replaces the 432K vendored copy)
      src/  mount.js  dom_bridge.js  bootstrap.js  hmr.js  dev_transport.js
            dev_reload.js  priority.js  boundary_registry.js  forms.js
    vite/                             # "@hydronium-js/vite"
      package.json                    # peer: vite ^8; dep: none beyond its own
      src/  index.ts  islands.ts  manifest.ts  dev-origin.ts
  examples/
    islands-tailwind/                 # the M1 proving ground: real island + real Tailwind
```

**Do not add `js/` as an `[[orbits.member]]`.** Orbit membership is for moonstone packages (`moonstone.toml`, `kind`, interpreter). This is a plain directory carrying an npm workspace. It only touches `moonstone.toml`/`partiture.lua` if built artifacts need to ship — which they do not before M3, and at M3 only via a *consuming app's* partiture (§5.1).

---

## 4. Milestones

Each milestone states a gate that can fail. If a gate fails, stop and report — do not proceed to the next.

### M0 — Extract the client runtime, with a drift check

1. Create the `hydronium/js/` workspace and both package skeletons.
2. Move `dom/src/hydronium_dom/client/*.js` into `packages/dom-client/src/` **byte-for-byte**. Replace the vendored `client/vendor/wasmoon/` with a real `wasmoon` dependency.
3. `dom/` must keep serving the same files at the same paths (the Lua server and `client_manifest.json` both reference them). Use a generated sync copy plus a drift check that fails when the copy diverges from the package source.
4. Update the **9 existing `tests/client/*.test.mjs`** import paths.
5. Install `playwright` + `playwright install chromium` as a devDependency of `hydronium/js`.

**Gate:** `node --test tests/client/*.test.mjs` fully green (this is the browser-free proof the move preserved behavior), **and** `luajit tests/runner.lua` still green, **and** the drift check fails when a file is deliberately edited on one side only.

### M1 — Vite 8 + Tailwind v4, standalone

Build `examples/islands-tailwind`: a real JS island (same `hydrate`/`mount`/`dispose` ABI as `examples/js_island/counter.js`) importing a real npm dependency and a Tailwind-using `.css` entry. Tailwind scans `.luax` via an explicit `@source "../../**/*.luax"` directive in the CSS entry — Tailwind does not know that extension otherwise.

**Gate:** `vite build` emits a real `dist/.vite/manifest.json` with hashed JS + CSS; a Playwright run proves `vite dev` HMR patches an edited island **without a full page reload** (assert a `window.__bootId` set once at boot is unchanged — the assertion that distinguishes HMR from live reload); and a Tailwind class used only inside a `.luax` file is present in the built CSS (proves `@source` works), while a class used nowhere is absent (proves the scan is still pruning).

### M2 — `hy_asset_ref` + dual dev server

1. Implement `hy_asset_ref` for real (`asset_id` + `specifier`, per the shape already specified in `HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md:217,250`). Do **not** invent a parallel mechanism.
2. Resolve it at render time in `dom/src/hydronium_dom/server/init.lua`, where `raw_props.module` is currently passed straight through: dev → Vite origin URL, prod → hashed `dist/` URL. Compiled modules must not inline final URLs.
3. CORS/dev-origin config in `@hydronium-js/vite`; a supervisor that starts Meteorite dev + `vite dev` together, forwards signals, and merges logs.

**Gate:** a Playwright run where a JS island hydrates from a module served off Vite's port, a click drives real state, editing that JS file HMR-patches without reload, **while** a co-located `.luax` component's Lua-side HMR is undisturbed on the same page. The two HMR systems visibly coexisting is the single highest-value experiment in this plan.

### M3 — Production manifest merge

New plugin `build/src/hydronium_ballad/plugins/vite_assets.lua`: ingest Vite's `dist/.vite/manifest.json` via `p.source.files` (the same intake shape `assets.lua` already uses) and re-emit each entry as a plain `hy_asset` matching **exactly** the shape `assets.lua` produces (`kind = "hy_asset"`, `metadata.hydronium = { source, url, integrity }`). Feed it into `site.lua`'s existing merge loop.

**`site.lua` should need zero changes.** Its merge already generalizes over any `hy_asset` with `metadata.hydronium.source`. If you find yourself editing `site.lua`, stop — the new plugin's output shape is wrong instead.

**Gate:** a page with a `d.js.island` served entirely from the merged `dist/` with **no Vite process running**, proven in Playwright; plus `luajit tests/runner.lua` still green.

---

## 4a. Honest status ledger (2026-09-25)

Per this workspace's own CLAUDE.md rule ("don't trust 'VERIFIED'/'Production
Ready' language without re-running the repro yourself"): this section
records what was actually found on disk and in CI this session, not what
an earlier session's docs *said*. Anyone picking this plan back up should
re-verify the "done" rows below with the cited commands before building on
top of them, exactly as this session did.

| Milestone | Status | Evidence checked this session |
|---|---|---|
| M0 (extract client runtime) | **Done** | `js/packages/dom-client/src/*.js`, `js/scripts/check-dom-client-drift.mjs`, CI job `web` runs the drift check and `node --test tests/client/*.test.mjs` |
| M1 (Vite 8 + Tailwind v4 standalone) | **Done** | `js/examples/islands-tailwind/` real app + `tests/hmr.test.mjs`, `tests/tailwind-source.test.mjs`; both wired into CI's `web` job |
| M2 (`hy_asset_ref` + dual dev server) | **Done** | `dom/src/hydronium_dom/server/vite_module.lua` (commit `6cb8a88`), `js/packages/vite/src/{plugin,dev-origin}.ts` (commit `a5f9a2e`, renamed to `@hydronium-js` scope in `42ad47e`), `js/packages/vite/src/supervisor.mjs` + `bin/dual-dev.mjs`, `tests/server/vite_module_spec.lua`, `js/packages/vite/tests/{supervisor,dual-dev}.test.mjs`. CI's `validate` job runs `tests/e2e/meteorite_vite_browser.sh` (the M2 dual-HMR + M3 production gate, both needing the full zig/moonstone/ballad toolchain, hence not in the lighter `web` job) |
| M3 (production manifest merge) | **Done** | `build/src/hydronium_ballad/plugins/vite_assets.lua` (commit `8d7432d`), `tests/build/vite_assets_spec.lua`. `site.lua` was in fact left unchanged, as the plan required |
| CI open question 3 ("should CI gain a node step?") | **Resolved: yes, already done** | `.github/workflows/ci.yml` has a second top-level job, `web`, plus a `meteorite_vite_browser.sh` step inside `validate` — this predates the "STEP 1" work below |

**What was actually missing when STEP 1 (below) started, verified by grep,
not assumption:** no `provider` concept anywhere in `dom/` or `build/`
(`grep -rn provider dom/src/hydronium_dom/assets.lua
dom/src/hydronium_dom/server/vite_module.lua
build/src/hydronium_ballad/plugins/vite_assets.lua` → zero hits), and no
`tags()` function on `hydronium_dom.assets`. `hy_asset_ref`/`vite_module`
resolve a single specifier to a single URL; they do not know how to
express "this entry also pulls in two CSS files and a shared chunk",
which is what a `<head>` full of `<link>`/`<script>` tags needs. That gap
is real STEP 1 scope, not a re-implementation of M2/M3.

Separately, verified still true and NOT part of STEP 1's fix:
`create/src/create/vite.lua` writes its own CSS-only `vite.config.js` and
hardcodes `/public/dist/styles.css`, using none of `@hydronium-js/vite` or
the asset-provider contract below. Its own header comment documents two
concrete, verified reasons a naive full integration was tried and reverted
(`hydronium_ballad.plugins.site`'s directory sink deletes a separately-run
`vite build`'s output; a dual dev server has nothing to serve when the
page has no Vite-owned HTML entry). Wiring the templates onto the
provider contract (this plan's STEP 2) has to account for both.

## 4b. The asset-provider contract (STEP 1, added 2026-09-25)

`hydronium_dom.assets` (`dom/src/hydronium_dom/assets.lua`) gained a small
provider interface so a Document component can ask for a build entry's
full markup without knowing whether Vite is involved at all:

```lua
local assets = require("hydronium_dom.assets")
assets.configure_provider({ provider = "static" | "vite-dev" | "vite-manifest", ... })

assets.provider()        --> the active provider name ("static" default)
assets.url(source)       --> single resolved URL; NEVER raises (dev-fallback, unchanged from before this step)
assets.tags(entry)       --> array of real d.link/d.script vnodes for `entry`, CSS first, then the entry's own tag;
                              RAISES for "vite-manifest" when `entry` was never declared as a build input
```

Three providers, one call to select:

- **`static`** (default, zero Node) — hydronium_ballad's own hashed
  `hydronium-manifest.lua`. Exactly the pre-existing
  `configure()`/`configure_table()` behavior; `tags()` on it emits one tag
  per entry (a flat manifest has no CSS/imports graph to walk).
- **`vite-dev`** — `{ provider = "vite-dev", vite_origin = "http://localhost:5173" }`.
  No manifest to read; every URL is the entry prefixed with Vite's own
  origin, matching `@hydronium-js/vite`'s `resolveDevOrigin`
  (`js/packages/vite/src/dev-origin.ts`) and `vite_module.lua`'s existing
  dev-mode resolution.
- **`vite-manifest`** — `{ provider = "vite-manifest", manifest_path = "dist/.vite/manifest.json" }`.
  Reads Vite's **real JSON** manifest directly (new:
  `hydronium_dom.server.json.decode`, a minimal JSON reader scoped to this
  one use — see that module's header for why `dom/`'s "zero runtime
  dependencies" rule doesn't reach for `dkjson` here) and walks
  `imports`/`css` transitively, so a JS entry's `tags()` includes CSS
  pulled in by chunks it imports, not just its own.

**Selection convention (the "one line of project config" the plan asks
for):** a project's own bootstrap (`main.lua` / the Meteorite entry point)
calls `assets.configure_provider(...)` exactly once, typically switching
on an env var:

```lua
if os.getenv("HYDRONIUM_VITE_MODE") == "dev" then
  assets.configure_provider({ provider = "vite-dev", vite_origin = os.getenv("HYDRONIUM_VITE_ORIGIN") })
else
  assets.configure_provider({ provider = "vite-manifest", manifest_path = "dist/.vite/manifest.json" })
end
```

This is a documented convention, not something `assets.lua` reads itself
— consistent with the module's pre-existing "no automatic discovery/magic
paths" stance. `create/src/create/vite.lua`'s scaffolded `islands`
template (§4d, done) is the real reference implementation, and it
actually uses a slightly different, more robust convention than the env
vars sketched above: it detects dev vs. prod by whether
`.hydronium/vite-dev.json` exists (published by `@hydronium-js/vite`'s
own dev plugin the instant its dev server binds a port — see
`js/packages/vite/src/plugin.ts`'s `devOriginFile`), which can never point
at a stale/dead port the way a hand-set env var surviving past its dev
session could. Critically, per §4d's finding #1, this bootstrap must be
inlined directly into the function that renders the Document, not called
from this file's own top level or a shared function.

**Deliberately NOT built in STEP 1:** `hydronium_ballad.plugins.vite_assets`
(the ballad-side ingestion that merges a Vite build into ONE
`hydronium-manifest.lua`, M3, already existed) still flattens each built
file into an independent `hy_asset` keyed by its own specifier — a JS
entry's associated CSS lands under the CSS file's *own* built path, not
attached to the JS entry. That means the post-merge **`static`** provider
cannot recover a JS entry's CSS/imports graph the way **`vite-manifest`**
(reading Vite's manifest directly) can. Both providers are real and
tested; they simply answer different questions — "what does hydronium's
own merged manifest say" vs. "what does Vite's own build graph say" — and
an app is free to pick whichever fits how it deploys. Reconciling this
(e.g. having `vite_assets.lua` additionally record `metadata.hydronium.css`
on the JS entry's own `hy_asset`) is future work, not required by any
STEP 1 gate.

**Test coverage:** `tests/host/assets_provider_spec.lua` (provider
selection, `tags()` for a CSS-only entry, a JS entry with CSS+imports,
the missing-entry error, and `vite-dev` origin prefixing) and
`tests/server/json_decode_spec.lua` (the new decoder). Full suite:
`moon exec -- luajit tests/runner.lua`.

## 4c. Decoupling guardrails (STEP 3, partial)

**3b (dependency lint) — done, 2026-09-25.**
`tests/build/vite_dependency_lint_spec.lua` mechanically enforces the
boundary this whole plan exists to protect: it parses every `require(...)`
call (not a raw substring search — a doc comment naming `vite_module.lua`
or `@hydronium-js/vite` in prose must not trip it) in `core/src`,
`router/src`, `query/src`, `table/src`, `virtual/src`, `ink/src`,
`luax/src`, `dom/src`, and fails if anything Vite-named is required from
outside two allowed files: `dom/src/hydronium_dom/server/vite_module.lua`
(the resolver itself) and `dom/src/hydronium_dom/server/init.lua` (M2's
one call site, resolving a `d.js.island` module through it). It also
separately asserts `hydronium_dom.assets` — STEP 1's neutral contract —
requires no Vite-specific module itself; "vite-dev"/"vite-manifest" are
opaque config-value strings a caller passes in, not something the module
reaches for. `build/` (hydronium_ballad) is deliberately out of scope:
`vite_assets.lua` is the ballad-side half of the same adapter and is
*expected* to know about Vite's manifest shape.

**3a (static-provider conformance) and 3c (wizard "Bundler: None" choice)
— NOT done.** Both depend on the `ssr`/`spa` templates (still the CSS-only
Vite side-build — see §4d) also moving onto the provider contract first:
3a's gate is "each Vite template also builds/serves with the static
provider and no Node"; 3c's "None ⇒ static provider" needs a real
static-provider code path for every template to fall back to, not just
`islands`.

---

## 4d. STEP 2, `islands` (2026-09-25) — done, gated for real

**What changed** (`create/src/create/vite.lua`'s `apply_islands`,
`create/src/create/tailwind.lua`, new `create/src/create/vite_vendor.lua`):
the Document renders its stylesheet via `assets.tags("src/styles.css")`
(no hardcoded `/public/dist/...` path); the JS island's `module` is a
plain Vite entry specifier (`"src/islands/counter.js"`), resolved dev/prod
by the already-wired `hydronium_dom.server.vite_module` (no explicit
`hy_asset_ref` call needed at the component level — `hydronium_dom.server.
init`'s ISLAND branch already does this for every `interpreter = "js"`
island); `vite.config.js` registers the real `@hydronium-js/vite` plugin
with both the island and the CSS entry as real build inputs; `moon run
dev` now runs a real dual dev-server (`scripts/dev.mjs`, `@hydronium-js/
vite`'s own `runDualDevServer`) instead of the old Vite-less `hydronium
dev`. Works for both router variants (`--router meteorite` default and
`--router hydronium`, which moves rendering into `src/app/page_handler.
lua`).

**`@hydronium-js/vite` distribution — decided: vendor the built package.**
Considered the three options the earlier draft of this plan named:
(a) a `file:` dependency into a sibling hydronium checkout — rejected,
breaks for any real user without this monorepo cloned next to their
project; (b) a real registry semver range now, with a documented manual
interim — rejected, makes `npm install` fail *today*, not just for some
future user; (c) **vendor the built package — chosen.**
`js/scripts/sync-vite-vendor.mjs` generates `create/src/create/
vite_vendor.lua` from a real `pnpm build` of `js/packages/vite` (dist/*.js,
dist/*.d.ts, dist/supervisor.mjs, a trimmed package.json, embedded as
literal Lua strings — the same reasoning `templates/islands.lua` already
uses for `public/js/bootstrap/*.js`); `js/scripts/check-vite-vendor-drift.
mjs` fails CI if it's stale. `apply_islands` writes those bytes into the
scaffolded project's own `vendor/hydronium-js-vite/`, and its
`package.json` depends on `"@hydronium-js/vite": "file:./vendor/
hydronium-js-vite"` — a real, self-contained local-directory dependency,
no sibling checkout required. Once published, this becomes a real semver
range and the vendoring goes away.

**Two real bugs found only by the live gate below, not by unit tests
(both now regression-tested in `create/tests/create_spec.lua`):**

1. **Meteorite's hybrid build requires an inline route handler to be
   fully self-contained ("source-liftable").** A shared `local function
   configure_vite()` called from the inline `"/"` handler fails `moon run
   build` outright ("hybrid inline handlers must be source-liftable ...
   move requires and mutable values inside the handler body"). Worse:
   configuring providers at `src/main.lua`'s own top level (outside any
   handler) **builds and runs with no error, but silently does nothing**
   — each lifted handler is independently loaded with its own fresh
   module cache, so `require("hydronium_dom.assets")` inside the handler
   is a *different* table than the one configured at the file's top
   level. The fix: inline the entire provider-bootstrap block directly
   into the function that calls `require("views.Document")` — the `"/"`
   handler in `src/main.lua` for the default router, or
   `src/app/page_handler.lua`'s `render` callback under `--router
   hydronium`.
2. **`base` must be `"/public/dist"`, not the default `"/"`.** Vite's
   manifest `file` paths are relative to its own `outDir`
   (`public/dist`), but the URL a browser fetches is resolved against
   Meteorite's `/public/:path*` static route — i.e. site-root-relative.
   Without this, every hashed asset URL 404s even though the SSR HTML
   looks completely plausible.

**Gate, run for real, both Tailwind on and off:** real scaffold (`lua
create/src/main.lua <dir> --template islands [--tailwind]`, hydronium/
core+luax+dom pointed at this checkout via `registry = "path"` — the
public moonstone registry only has the last *published* versions, which
predate STEP 1's new `hydronium_dom.assets` API) → `moon sync` → `npm
install` → `npm run build` (real `vite build`, real hashed manifest) →
`moon run build` (real `meteorite build --mode release-hybrid`, real
`zig` compile) → real `./dist/server` → `curl` the page and **every**
asset URL it references (all 200, both variants) → a real headless
Chromium (Playwright, already installed in `js/`) loads the page, reads
`window` state via `getByTestId("js-counter-btn")`, asserts `"Count: 10"`
initially, clicks it, asserts `"Count: 11"` — real island hydration
through the actual Vite-built, hashed JS file — with zero console errors,
zero page errors, zero failed requests, for both Tailwind on and off.
Servers killed after each run; Ink Lab (`:6100`) never touched.

**Not done for `islands` in this pass:** wiring `moon run dev`'s new dual
dev-server into an *automated* CI gate (it was verified manually via the
production path above, not via `vite dev` + HMR — that's STEP 4); the
`--router hydronium` + Tailwind combination was verified only by unit
test (file-content assertions), not a second live build/curl/browser
pass, since the underlying render mechanism (`page_handler.lua`'s
`render` callback) is identical to what the live-verified default variant
already exercises.

---

## 5. Hazards — read before writing code

1. **Do not make the root `partiture.lua` depend on Vite output.** CI's last step is `ballad play partiture.lua`, and CI has **no node/npm step whatsoever**. A framework-level partiture that requires `dist/.vite/manifest.json` breaks CI immediately. `vite_assets` belongs in *consuming app* partitures, and must degrade gracefully when the manifest is absent.
2. **`metadata.hydronium` namespacing is mandatory.** Ballad copies metadata verbatim into cache-entry JSON and `file-graph.json`; bare top-level keys collide silently.
3. **Cacheable ballad methods may not take function-valued options** — `serialize()` errors on them. Plain data only.
4. **`p.sink.directory` calls `remove_tree` first.** One sink per output tree, or strictly disjoint `out` paths.
5. **Never let any JS-side pass rewrite a `scope_class` string literal.**
6. **`client_plan` is v1 and SSR-only by its own comment.** A pure static-export build has no `client_plan` unless it prerenders. Assert its shape rather than assuming it.
7. **The working tree is busy.** `git status` shows extensive concurrent, uncommitted work from other sessions across `core/`, `create/`, `ink/`, `meteorite/`, `examples/`. Touch only files this plan names. Do not commit anything you did not write. Do not run destructive git commands.
8. **Tailwind's scanner has the same soundness rule as the require lint:** class names must appear as complete literal strings in source. `"bg-" .. color` is invisible to it. Document this; do not try to defeat it.

---

## 6. Open questions

1. **npm org `hydronium`** — ownership unverified. Irrelevant until a publish is attempted; M0–M3 use workspace links only.
2. **pnpm vs bun** as the workspace manager. Both installed. Bun has precedent here (`build/tests/web-build.test.ts`); pnpm is the safer default for Vite plugin authoring. **[UNVERIFIED]** either way — implementer's call, stated in the PR.
3. **Should CI gain a node step** to run the `.mjs` tests and the new gates? Today it would not catch a regression in any of this. Recommended, but a separate change from this plan.
4. **Static export + PWA** (`build/web/*.ts`) overlaps conceptually with Vite's build. Not touched here; worth reconciling later.
