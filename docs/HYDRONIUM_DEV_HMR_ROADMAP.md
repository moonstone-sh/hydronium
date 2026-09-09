# Hydronium → Vite-comparable dev DX: gap assessment + roadmap

**Produced by:** an Opus 5 planning agent, read-only investigation against the live hydronium working tree (post `e686f78`, the hydronium-ballad build pipeline commit). Verified empirically where possible (a real throwaway `luajit` probe, a real `luajit tests/runner.lua` run), not just by reading docs — per this repo's own `CLAUDE.md` norm against trusting self-certifying claims.

**The ask this answers:** "CLI `create` → run `moon run dev` → state-preserving true HMR for Hydronium. The idea is that the DX is on par with, or better than, Vite."

---

## Headline

The gap is **moderate on infrastructure, large on the two things that actually define the experience**. Nearly every hard *mechanism* exists and is genuinely proven. What does not exist is (a) an automatic path from ordinary component source to preserved state, and (b) any client-side HMR runtime — today the browser's response to a file change is `location.reload()`.

The single most important finding, established empirically rather than from docs:

```
plain createSignal       before=Count: 12   afterReload=Count: 10   afterClick=Count: 15   refreshed=1 failed=0
refresh_registry:signal  before=Count: 12   afterReload=Count: 12   afterClick=Count: 17   refreshed=1 failed=0
```

Same harness, same real `family_loader.reload()`, same real reconciliation. A component written the ordinary way (`signals.createSignal(0)`) **loses its state** (12 → 10). A component written with a hand-authored descriptor keeps it. Both correctly pick up the new logic. So HMR *transport and refresh* work; **state preservation is opt-in per signal, by hand.**

---

## What is genuinely real and reusable

Named, verified by reading the code and running it:

- **`core/src/hydronium/core/family.lua`** — `Family:update_definition()` (line 61) snapshots live instances and calls `instance:refresh()` on each. Real, correct, guards against mutation-during-iteration.
- **`core/src/hydronium/core/family_loader.lua`** — wraps `_G.require` (line 88) to auto-discover components by `"<module_id>::<export>"`; `.reload(module_id)` (line 124) clears `package.loaded`, re-requires, re-scans, fans out. **Zero per-component registration.** This is the right identity model and it works.
- **`core/src/hydronium/core/component.lua:406` `ComponentInstance:refresh()`** — disposes the old scope, makes a fresh one, re-attaches the *persistent* `refresh_registry` (line 424), clears `renderFn`, re-renders through ordinary reconciliation. No bespoke HMR diff engine. Correct design.
- **`core/src/hydronium/core/refresh.lua`** — the `{kind, name, block_path}` matcher including a conservative rename heuristic (only when exactly one unmatched candidate exists per side, line 119). The algorithm is sound.
- **`dom/src/hydronium_dom/client/dev_transport.js`** — a real, hard-won SSE transport with client-tracked `?since=` fingerprints and cache-busting, both of which are documented as fixes for *observed live browser behavior*, not theory. Reusable as-is.
- **`dom/src/hydronium_dom/dev/watch.lua`** — the fingerprint + SSE protocol promoted out of the example into framework code. Note: **it currently has zero consumers in `examples/`** (the example still inlines its own copy); the `hydronium-create` `ssr` template does call it (`watch.serve_sse(c, {...})`).
- **`dom/src/hydronium_dom/client/mount.js`** — already supports **both** loading paths in one function: `chunkUrls` (bundled, line 149) and `hydroniumBaseUrl`/`manifestUrl`/`appModuleUrl` (unbundled, line 159–176). This matters a lot for the architecture question below.
- **`examples/meteorite_ssr/hmr_demo/dom_host_proof.html`** — this is a **real** state-preserving HMR proof and it holds up: real wasmoon VM, real DOM, real disk edit, real transport, `family_loader.reload()` → 2 instances refreshed, unrelated DOM nodes asserted identical by `===`, counters preserved at 12 and 37, new logic active. That is genuine end-to-end HMR. Its limits are that it is a hand-built bespoke page with modules inlined as a giant `EMBEDDED_MODULES` literal, fetching from hardcoded one-off routes, driving `package.preload` from JS by hand.
- **`luax/src/hydronium_luax/loader.lua`** (untracked/new) — mtime-keyed compile-on-demand for `.luax`. Real and useful.
- **Fine-grained bindings (uncommitted, separately under review).** Correctness not re-verified here — a separate Opus agent owns that. One HMR-specific question was checked: **the binding effects are created inside `scopeModule.runWithScope(parentComponent.scope, attach)`**, so they are owned by the component scope and are therefore disposed by `refresh()`'s `old_scope:dispose()`. **Fine-grained bindings are HMR-compatible by construction** — relevant if verified, verification pending. They are a nice-to-have for HMR, not a prerequisite: the granularity HMR needs (which *instances* re-run setup) is already provided by `Family`.

---

## Answers to the four investigation items

### 1. `hydronium/create` — real path is `/Users/extrordinaire/Workbench/user/hydronium-create` (confirmed sibling)

- Templates: `ssr`, `islands`, `minimal` are live; **`spa` exists on disk but is deliberately disabled** — `src/create/init.lua:71` fails loudly with an explanation, and `templates/spa.lua`'s header lists exactly what's missing. Unusually honest scaffolding, worth preserving as a pattern.
- **A `dev` script already exists.** `templates/ssr.lua:107` and `templates/islands.lua:62` emit `[scripts] dev = "moon exec --dev meteorite dev --mode hybrid_dev --backend fast_http --lua-root ..."`, and `src/main.lua:77` prints `moon run dev` as the next step. `hybrid_dev` is a real meteorite profile (`meteorite/src/core/profile.lua:98`). A real scaffolded project from this CLI exists at `/Users/extrordinaire/Workbench/user/hydronium-hmr-KoHP5G` with a populated `.meteorite/` and `dist/`.
- **It uses the OLD unbundled API** — `templates/ssr.lua:216-220` passes `hydroniumBaseUrl`/`manifestUrl`/`appModuleUrl`, not `chunkUrls`. But see the resolved architecture question below: this is arguably the *right* choice for dev, not legacy debt.
- The scaffolded counter is *already* authored HMR-ready — `templates/ssr.lua:374` writes `scope.refresh_registry:signal(props.initial or 0, {kind="signal", name="count", block_path=...})`. A fresh project ships a component whose state *could* survive a hot swap. It never gets the chance, because `templates/ssr.lua:226` loads `dev_reload.js`, which reloads the page.

### 2. State-preservation infrastructure — real, but not automatic

- `refresh.lua`'s own header claims it is "NOT wired into the LUAX compiler, the component runtime, or any dev transport." Half of that is stale: `component.lua:67-68` and `:217/:219` DO wire it into the runtime. **The compiler half is exactly true** — `grep` for `refresh_registry|block_path|descriptor` across `luax/src/` returns **zero hits**. There is no compiler pass attaching descriptors.
- Consequence, confirmed by the probe above: **every component not hand-annotated loses state on hot swap.**
- Proven through a real file-edit → real reload cycle? Yes, but only in the bespoke proof pages, and only for hand-annotated components.
- The HMR docs are currently modified in the working tree, and — contrary to this repo's documented trust problem — **this particular doc set is not over-claiming** and matched the code everywhere checked (e.g. `HMR_DOM_HOST.md:51` still honestly reads "NOT YET COMPLETE").

### 3. Dev mode vs. the new bundler — a completely open gap, acknowledged but unaddressed

`grep` across `build/src/hydronium_ballad/` for dev/watch/hmr/incremental returns only `opts.development` on the luax plugin, a compiler-debug flag, not a dev-server mode. The architecture plan itself names the tension:

- `docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md:520` — *"HMR through the bundler — the existing HMR path works because nothing is bundled; wire `ballad.plugins.watcher` in only after M2."*
- `docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md:45` — explicitly notes `dev_reload.js:16` destroys the VM via `location.reload()` "even on HMR."
- `docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md:123` designs a dual dev/prod path via a `loader.install()` package searcher — **which does not exist**: `loader.lua` has only `M.load` and `M.invalidate`.

### 4. Vite comparison, feature by feature

| Vite capability | Hydronium today | Evidence |
|---|---|---|
| (a) Instant dev server, no bundling for initial load | **Partial→good.** Server side is genuinely excellent: `hybrid_dev` gives a fresh Lua state per request and `luax/loader.lua` recompiles on mtime change, so SSR needs no build step. Client side, the unbundled `mount()` path exists but fetches every framework module individually. | `loader.lua:56`, `mount.js:159-176` |
| (b) File watcher, sub-100ms push | **Partial, an order of magnitude off.** `watch.lua` defaults `POLL_INTERVAL = 0.5s`, each tick shells out to `stat` per watched file via `io.popen`. Watches a hand-listed file array, not a dependency graph. | `dom/.../dev/watch.lua:31,49-58,126` |
| (c) Client HMR runtime that hot-swaps one module | **Zero.** `dev_reload.js` is 18 lines and calls `location.reload()`. All real hot-swapping logic lives inside two one-off proof HTML pages. | `dev_reload.js:15-17` |
| (d) Graceful fallback to full reload | **Inverted.** Full reload is not the fallback — it is the only behavior. | `family_loader.lua:115` (the right primitive to build the decision logic on) |
| (e) Error overlay | **Zero.** No hits for "overlay" anywhere in source or templates. | verified |

One structural advantage worth naming: because the client runs a **persistent Lua VM** with a real `package.loaded` registry, `family_loader.reload()` is a far more natural HMR primitive than anything JS has to invent. The hard part of HMR is already solved *inside* the VM. The missing work is almost entirely around it.

---

## The architectural question, resolved

**Recommendation: split the boundary the way Vite actually splits it — `mount.js` already supports both halves today.**

Vite pre-bundles *dependencies* (change rarely, cache well) and serves *your source* unbundled and individually (changes constantly, per-module granularity is what makes HMR possible). Apply that split verbatim:

- **Framework code** (`hydronium.*`, `hydronium_dom.*`, ~40 modules, changes only on upgrade) → build **once** with the existing `hydronium_ballad` `client.bundle()` into a single hashed, long-cached chunk.
- **Application code** (`views/*.luax`, `src/client/*.lua`, changes every keystroke) → serve **unbundled, one module per URL**, compiled on demand by `luax/loader.lua`. Never rebundle on save.
- `mount({ chunkUrls: [framework], manifestUrl: <app-only manifest> })` — a mixed call the existing `mount.js` can already express with a small change.

This means **the "old" unbundled API is not legacy debt to migrate off — it is the dev-mode API**, and the `ssr` template is already on the right one.

---

## Roadmap

### M0 — Close the honesty gaps (small, do first)
1. Fix `refresh.lua`'s stale header (claims it isn't wired into the runtime; it is — `component.lua:67`).
2. Make `examples/meteorite_ssr/src/main.lua` consume `hydronium_dom.dev.watch` instead of its inlined copy — the framework module currently has zero real consumers outside the create template.

### M1 — Automatic state preservation ⭐ *the single highest-leverage item*
Build the `.luax` compiler pass that rewrites `createSignal(x)` at each call site into `scope.refresh_registry:signal(x, {kind="signal", name=<binding name>, block_path=<enclosing function path>})`. Everything downstream already exists — descriptor schema, matcher, rename heuristic, per-instance registry lifetime. The compiler already has the AST and source positions; this is a well-scoped pass, not research.

**Honest limitation to decide up front:** this only helps `.luax` files where `scope` is lexically in scope. The `ssr` template's own client counter is plain Lua (`src/client/counter.lua`) — exactly why it hand-writes the descriptor today. Either migrate that template component to `.luax`, or keep the manual form as the documented plain-Lua path. Pick one deliberately.

### M2 — Client HMR runtime (`dom/src/hydronium_dom/client/hmr.js`)
Generalize what the two proof pages do by hand into one real module: subscribe to `dev_transport`, receive a **module id** (not just "something changed"), fetch that module's compiled source from a generic route, `package.preload[id] = load(src)` then `family_loader.reload(id)` inside the surviving VM; if the id maps to no family, **fall back to `location.reload()`** (Vite item d, ~10 lines once the lookup exists). Requires the SSE frame to carry a changed-module identity (per-file fingerprints, not a whole-set digest).

### M3 — Dev server as a real mode
- Implement the `loader.install()` package searcher that `LUAX_BALLAD_CSS_ASSETS_PLAN.md` designs but doesn't yet exist, so `require("views.App")` works identically in dev and prod.
- A generic `/__hydronium/dev/module/:id` route replacing the bespoke one-offs.
- The framework-bundle/app-unbundled split above.
- Move `hydronium-create`'s `dev` script to a real `hydronium dev` rather than raw `meteorite dev` flags — the two templates already drift.

### M4 — Latency
Replace the 0.5s `io.popen`-per-tick poll with a real watcher (`ballad.plugins.watcher` is named in the architecture plan) and per-file dirty tracking. Target: edit→DOM under 150ms.

### M5 — Error overlay
Compile errors from `loader.lua` already carry filename/position via existing source maps; render into a DOM overlay instead of throwing.

---

## Definition of done for M1+M2 (the early, provable milestone)

A Playwright script against a **real scaffolded project** created by `hydronium/create` and started with a plain `moon run dev` — no bespoke proof page, no hardcoded demo route:

1. Loads the app, asserts the counter reads `Count: 0`.
2. Clicks 3× via real DOM events → `Count: 3`.
3. Records DOM node references for the counter and an unrelated sibling.
4. **Writes to a real `.luax` file on disk**, changing `+1` to `+5`, where that file declares state as a plain `createSignal(0)` — not a hand-written descriptor.
5. Waits for the update with **no page navigation** (e.g. a `window.__bootId` set once at boot, asserted unchanged — the assertion that distinguishes HMR from live reload, which today's `dev_reload.js` would fail).
6. Asserts the counter still reads **`Count: 3`**.
7. Asserts both DOM node references are still `===` the live nodes.
8. Clicks once → **`Count: 8`**, proving the new logic is live and the old listener didn't also fire.

Today the repo can pass 1–3, 7 and 8 (via `dom_host_proof.html`), and fails 4 (needs a descriptor), 5 (`location.reload()`), and consequently 6.

---

## Risks and open questions not resolved read-only

- **Not verified: does `moon run dev` actually serve a working page end-to-end right now?** The script exists, `hybrid_dev` is real, a scaffolded project with build artifacts exists — but no server was actually started (that's outside "read-only"). Treat "scaffold → running app" as *likely* working but unproven. **This should be the first thing anyone re-verifies.**
- **Meteorite has no WebSockets** (`meteorite/src/core/app.lua:198-215` deliberately errors on `unsupported_websocket`). All of M2/M4 must stay on bounded-long-poll SSE, putting a floor under latency a real socket wouldn't have. Whether sub-100ms is reachable at all over this transport is genuinely open.
- **Fine-grained bindings and Suspense v2 are uncommitted and under separate concurrent verification.** This plan doesn't depend on them; the one HMR-specific check (scope ownership of binding effects) suggests they'd compose correctly, but that's contingent on the other review's verdict, not independent confirmation.
- **`refresh.lua:98` writes `accessor._signal.value` directly**, bypassing the setter, so the value copy fires no dependency notifications. Safe today (runs in `finish_generation` before any render). With fine-grained bindings creating effects that subscribe directly to accessors, this deserves a re-look once that feature is verified.
- **The rename heuristic will produce surprises at scale.** Only matches when exactly one candidate exists per side per kind (`refresh.lua:119`). Correct and conservative, but users will read it as a bug; needs documenting wherever M1 ships.
- **No dependency graph anywhere** (`HMR_COMPONENT_FAMILIES.md:6` flags this as deliberately deferred). Editing a non-component module can never propagate to its dependents until M3+; must fall back to full reload, which is fine only once M2's fallback actually exists.
- `CLAUDE.md` is stale on test counts (says 24 suites/311 specs; real run is 454/454 in 0.091s) — a reminder that a green suite verifies nothing about DX on its own, and didn't here: it passes today while ordinary components lose all state on hot swap.
