# `@hydronium/vite`: the web-asset adapter plan

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
2. **Two packages:** `@hydronium/dom-client` (the runtime: mount, bridge, HMR client, islands bootstrap) and `@hydronium/vite` (the build/dev adapter). Split because `dom-client` must keep working with **no bundler at all** — a bare `<script type="module">` — which `bootstrap.js`'s own header claims today; folding the plugin in would force a `vite` dependency on every consumer.
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
    dom-client/                       # "@hydronium/dom-client"
      package.json                    # dep: wasmoon (replaces the 432K vendored copy)
      src/  mount.js  dom_bridge.js  bootstrap.js  hmr.js  dev_transport.js
            dev_reload.js  priority.js  boundary_registry.js  forms.js
    vite/                             # "@hydronium/vite"
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
3. CORS/dev-origin config in `@hydronium/vite`; a supervisor that starts Meteorite dev + `vite dev` together, forwards signals, and merges logs.

**Gate:** a Playwright run where a JS island hydrates from a module served off Vite's port, a click drives real state, editing that JS file HMR-patches without reload, **while** a co-located `.luax` component's Lua-side HMR is undisturbed on the same page. The two HMR systems visibly coexisting is the single highest-value experiment in this plan.

### M3 — Production manifest merge

New plugin `build/src/hydronium_ballad/plugins/vite_assets.lua`: ingest Vite's `dist/.vite/manifest.json` via `p.source.files` (the same intake shape `assets.lua` already uses) and re-emit each entry as a plain `hy_asset` matching **exactly** the shape `assets.lua` produces (`kind = "hy_asset"`, `metadata.hydronium = { source, url, integrity }`). Feed it into `site.lua`'s existing merge loop.

**`site.lua` should need zero changes.** Its merge already generalizes over any `hy_asset` with `metadata.hydronium.source`. If you find yourself editing `site.lua`, stop — the new plugin's output shape is wrong instead.

**Gate:** a page with a `d.js.island` served entirely from the merged `dist/` with **no Vite process running**, proven in Playwright; plus `luajit tests/runner.lua` still green.

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
