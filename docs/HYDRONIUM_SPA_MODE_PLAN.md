# Hydronium SPA mode: hash routing, a bundled router, and a closed Lua asset path

**Scope:** ship a Hydronium app that runs entirely in the browser — framework, router and application all in Lua chunks, hash-routed, deployable to a static host — and then layer SSR first paint on top of it without giving that up.

**Method:** written to this workspace's standard (`CLAUDE.md`, "Trust issue in `docs/`"). Every claim below is either backed by a command run read-only against this tree on 2026-09-23, or labelled **[UNVERIFIED]**. Milestones state gates that can fail.

**Companion docs:** `HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md` (the JS/CSS half, M0–M3 complete), `HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md` (the Lua bundler), `HYDRONIUM_DEV_HMR_ROADMAP.md`.

---

## 0. Verification ledger

| Claim | How verified | Result |
|---|---|---|
| No hash history exists | `ls router/src/hydronium_router/history/`, grep for `hashchange`/`location.hash` across `router/src` | **True.** Only `browser.lua`, `memory.lua`, `init.lua`, `state.lua`. Zero hits for either hash API |
| The History contract is small and explicit | `history/init.lua:81` | 9 methods: `current`, `push`, `replace`, `go`, `back`, `forward`, `can_go_back`, `can_go_forward`, `dispose`, enforced by `M.validate` |
| The router already accepts any conforming adapter | `router.lua:142,145` | `create_router` **requires** `opts.history` and validates it. Swappability exists at the API level already; what is missing is a hash implementation and a way to *choose* one |
| The router has never been bundled | grep `hydronium_router` across `build/src` and every `examples/*/partiture.lua` | **Zero hits.** No client chunk has ever contained the router |
| `MOUNT_BOOTSTRAP_ENTRIES` does not include it | `plugins/client.lua:298-305` | Six entries, all `hydronium.*`/`hydronium_dom.*` |
| `browser.lua` depends on JS-side globals | `history/browser.lua:48,58` | Reads `_G.__router_push_state`, `__router_on_popstate`, etc. A Lua history adapter is only half an adapter; the other half is a JS bridge (`router/client/history.js`) |
| The ballad CSS/asset plugins have no coverage | grep for `hydronium_ballad.plugins.style`/`.assets` across `tests/` | **None.** `tests/host/css_spec.lua` and `assets_spec.lua` exercise the `hydronium_dom` runtime, not the build plugins |
| The `spa` template's three blockers | `create/src/create/templates/spa.lua:1-40` vs current tree | It cites no `h.mount`, no client bootstrap, no `.luax` bundler. The latter two are now resolved (`mount.js` + `hydronium_ballad.plugins.client`, both browser-verified). The first is a naming/shape question, not a missing capability |
| Root client mount works | `HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md` M1/M2 gates | `mount({ chunkUrls, appModuleId, container, hydrate: false })` renders and updates a real component tree. This IS the SPA entry point |

---

## 1. Decisions taken (2026-09-23)

1. **Both modes, static SPA proven first.** The pure-client path is the foundation and must stand alone; SSR first paint is a second milestone layered on it. If the SSR handoff proves thorny, the static path still ships.
2. **Hash now, mode swappable.** Add `history/hash.lua`, and make history selection a first-class, documented configuration choice rather than an implicit constructor argument.
3. **Full breadth.** Router bundling, hash history, CSS and static assets through the two untested build plugins, the disabled `spa` template, and browser gates. An SPA has no SSR fallback to hide a broken asset URL, so the asset path has to be closed here rather than deferred.

---

## 2. What SPA mode means concretely

### 2.1 Mode A — static SPA (the foundation)

One HTML shell, served by anything (`python -m http.server` is a valid host). It loads `mount.js`, which loads the Lua chunks, which contain `hydronium`, `hydronium_router` and the app. The router reads `location.hash`. Navigation never touches the network. No Meteorite, no server rewrite rules, no SSR.

The artifact is what `hydronium_ballad` already produces, plus the router in the graph:

```
dist/
  index.html                  # the shell: one <div id="app">, one <script type="module">
  client/runtime-<hash>.lua   # hydronium + hydronium_dom + hydronium_router
  client/entry-<hash>.lua     # the app
  assets/app-<hash>.css       # from plugins.style
  assets/<name>-<hash>.<ext>  # from plugins.assets
  hydronium-manifest.lua      # the join table both of the above resolve through
```

### 2.2 Mode B — SSR first paint, then client routing

Meteorite SSRs the initial route; the same chunks hydrate; the router takes over and subsequent navigations are client-side. This is Mode A plus a hydrate step and a server that can render each route — which the `render_page` scope and the M4-verified hydrate path already support.

**Mode B is not a different build.** It is Mode A's chunks plus SSR markup, which is why A is the foundation.

---

## 3. The history adapter

`create_router` already validates and accepts any table implementing the 9-method contract, so the work is an implementation and a selection mechanism, not a refactor.

**`history/hash.lua`** implements the contract over `location.hash` + `hashchange`. It mirrors `memory.lua` (which proves the contract supports a non-pushState backend) rather than `browser.lua`.

**The JS half.** `browser.lua` reads `_G.__router_*` globals that `router/client/history.js` supplies. A hash adapter needs the same shape of bridge — a `hashchange` listener and hash read/write. Two things to decide while doing it:

- `router/client/*.js` sits outside `@hydronium/dom-client`, so a browser SPA currently has a second, unpackaged pile of client JS. It should move into the package alongside `mount.js`, with the same generated-copy + drift check.
- The globals contract (`__router_*`) is ambient and unvalidated on the JS side. Hash mode doubles the number of implementations reading it, which is the moment to give it a named export instead.

**Selection.** Make the mode explicit and documented — `create_router { history = hydronium_router.createHashHistory() }` is already possible; what is missing is (a) the hash implementation, (b) a documented recommendation per deployment target, and (c) the scaffold choosing correctly. Avoid a magic "detect the environment" default: a silent fallback between pushState and hash is precisely the kind of thing that works in dev and 404s in production.

---

## 4. Milestones

### M1 — `history/hash.lua` + its JS bridge

The adapter and the `hashchange` bridge, no bundling, no app.

**Gate:** unit specs against the contract (all 9 methods, `validate` passes, round-trips through `current`/`push`/`replace`/`go`, and `dispose` detaches the listener), plus a real browser check that a `hashchange` reaches a subscriber. Must not regress `memory`/`browser`.

### M2 — bundle the router

Add `hydronium_router` to a client chunk for the first time. This is the milestone most likely to surface something unpleasant, because the router is the largest module set yet added to a bundle and has never been through `client.resolve`.

**Gate:** `client.resolve` walks the router with no unresolved requires, the require-discipline lint passes over it clean, and the emitted chunk `load()`s in a fresh isolated Lua state. Specifically watch for `debug.getinfo` (`resolve` already refuses it) and any computed require the lint will now catch.

### M3 — a real static SPA, gated in a browser

An app with two routes, mounted with `hydrate: false`, served by a dumb static file server with **no Meteorite process at all**.

**Gate:** Playwright — initial route renders; clicking a link changes `location.hash` and swaps the view with **no navigation** (assert a boot id set once, as the existing HMR gates do); back/forward work; a hard reload at `#/second` lands on the second route, not the first (the assertion that actually proves hash routing rather than a click handler); and zero requests to any origin beyond the static host.

### M4 — close the asset path

The two build plugins the SPA depends on and nothing currently tests: `plugins.style` (component-scoped CSS) and `plugins.assets` (content-hashed static files).

**Gate:** specs for both, mirroring `vite_assets_spec.lua`'s shape — including one that feeds real output into the real, unmodified `site.manifest`. Then extend M3's browser gate: a scoped class from a `.luax` component actually applies, and a static asset referenced by a component resolves to its hashed URL and returns 200. Without this, an SPA's first broken asset URL is a blank page with no server-side fallback.

### M5 — the `spa` template, re-enabled

Re-check all three blockers `spa.lua` documents before re-enabling — two are resolved, the third (`h.mount`) is a shape question to settle deliberately: either expose `h.mount(component, selector)` as the documented SPA entry or update the template to use `mount({...})` and delete the claim.

**Gate:** scaffold a project with `hydronium-create --template spa`, build it, serve it statically, and run M3's browser gate against *that* project rather than a hand-built fixture.

### M6 — Mode B: SSR first paint

Only after A is green. Meteorite SSRs the initial route into the same shell; the same chunks hydrate; the router takes over.

**Gate:** first paint contains real route markup (not an empty shell), hydration preserves DOM node identity (the M4 hydrate finding in the ballad plan), and a subsequent navigation is client-side with no document request.

---

## 5. Hazards

1. **`h.mount` naming.** Resolve it once, in M5, and make the docs and template agree. Right now `spa.lua` asserts an API gap that is really a shape difference.
2. **Two piles of client JS.** `router/client/` is outside `@hydronium/dom-client`. Fold it in during M1 or the SPA ships an unpackaged, undrift-checked second copy.
3. **The `__router_*` ambient globals** are unvalidated and about to gain a second consumer.
4. **No SSR fallback.** Every asset-path defect in Mode A is a blank page. This is why M4 is in scope rather than deferred.
5. **Tree-shaking and the router.** `resolve()` drops unreached modules. A router that resolves route components dynamically is exactly the shape that looks unreachable to a static walk — the require-discipline lint will now *fail the build* rather than silently under-bundle, which is the desired behaviour, but expect to hit it and to need explicit entries.
6. **`client_plan` is SSR-only by its own comment.** A pure static export has no client plan unless it prerenders. Mode A must not grow a dependency on it.

---

## 6. Open questions

1. Does `hydronium_router` bundle cleanly at all? Unknown until M2 — nothing has ever tried.
2. Should the static shell be emitted by a build plugin (`plugins.site` knows the chunk URLs) or written by hand in the template? The former is better; it is also new plugin surface.
3. Is `hydronium_router.site`/`meteorite.lua` reachable from a Mode A build, and should it be? It exists for the SSR path and may pull server-only code into a client chunk.
4. Hash-mode base paths: an app served from a subdirectory. Worth deciding before M3 rather than after.
