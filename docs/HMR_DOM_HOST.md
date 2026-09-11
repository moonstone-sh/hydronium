# Real DOM Host for the General Reconciler (Counter-Agent Audit Response)

This closes the single biggest gap the counter-audit of the HMR
generalization work surfaced: **nothing in this codebase implemented
the Reconciler's actual Host contract against a real browser DOM.**
Only two things existed: a narrow, hand-written, button-only bridge
(`hydronium.interpreter.lua`) that bypasses the reconciler entirely, and
`hydronium.test.createTestHost()`, an in-memory fake used by the test
suite. This document is the ground-truth record of what closes that gap
and what still doesn't.

## Part I — Tracing the OLD proof's actual path (before this round)

The previous "real WASM Lua HMR proof" (`hmr_demo/index.html`,
documented in `docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md`'s "both
client-side halves closed" section) and the family-generalization proof
that followed it (`hmr_demo/family_proof.html`) both claimed to run
against "a real DOM" or "real reconciliation." Traced edge by edge:

```
SSR
  -> marker                          GENERAL (server/init.lua's real <!--hy:i:...--> comments)
  -> browser
  -> WASM Lua                        GENERAL (real wasmoon, real Lua 5.4)
  -> ComponentFamily                 GENERAL (this session's own prior work)
  -> ComponentInstance                GENERAL
  -> Scope recreation                 GENERAL
  -> RefreshRegistry                  GENERAL
  -> reconciler                       PARTIAL: only in family_proof.html, and even there
                                       bound to TestHost (in-memory), not a real DOM Host
  -> ??? DOM mutation mechanism       hmr_demo/index.html: DEMO-SPECIFIC. hy_find_island/
                                       hy_query_button/hy_set_text/hy_on_click bypass
                                       core.reconciler and core.component ENTIRELY --
                                       one hand-written signal wired directly to one
                                       hand-found <button>. family_proof.html: the "???"
                                       was never real DOM at all -- TestHost, an in-memory
                                       tree, inside the WASM VM. Both were honestly labeled
                                       as such in their own docs at the time, but the
                                       PLAIN-LANGUAGE summary line in the prior final report
                                       ("real DOM") was stronger than either proof's actual
                                       reach -- exactly the "stronger claim than executable
                                       evidence" pattern this project's own CLAUDE.md already
                                       warns about for OTHER docs in this repo.
```

**Corrected release language** (counter-audit Part 1's own required
format):

```
RUNTIME COMPONENT-FAMILY HMR GENERALIZATION (prior round):  VERIFIED
END-TO-END AUTOMATIC HYDRONIUM HMR (prior round):           NOT YET COMPLETE
```

The prior round's own report already scored itself 9/15 hard gates and
listed "no real browser DOM Host adapter" as a newly-surfaced gap in
plain language -- it did not claim "HMR COMPLETE." The correction here
is narrower: the *summary line* "real browser (Chromium via Playwright)"
in that report's evidence section was true for the transport/event
layer and the WASM VM, but invited reading "real DOM" into the render
layer, which was actually TestHost. This document's own claims below
are scoped to avoid that same ambiguity: every "real DOM" claim here
names the actual browser `Element`/`Text` objects and is checked via
Playwright's `page.evaluate` reading real `document.getElementById(...)`
results, never TestHost.

## Part II — What "no real DOM Host adapter" meant concretely

The Reconciler's actual Host contract (`core/reconciler.lua`, confirmed
by reading `Reconciler:mount`/`:reconcile`/`:unmount` directly, and
cross-checked against `TestHost`'s implementation) is exactly:

```
createInstance(tag, props) -> hostNode
createTextInstance(text) -> hostNode
appendChild(parent, child)
insertBefore(parent, child, beforeChild)
removeChild(parent, child)
commitUpdate(hostNode, oldProps, newProps)
commitTextUpdate(hostNode, oldText, newText)
```

Seven methods -- no `begin_commit`/`end_commit` batching hook, no
built-in hydration API (that didn't exist at all before this round; see
Part IV). `hydronium.interpreter.lua`'s `hy_find_island`/`hy_query_button`/
`hy_get_text`/`hy_set_text`/`hy_on_click` bypass ALL seven -- it is not
a Host implementation, it never claimed to be, and its own doc comment
says exactly this ("no re-entry into hydronium.core.reconciler").

## Part III — What `src/hydronium/host/dom.lua` actually is

A real implementation of all seven methods against a real DOM, via a
small, generic bridge contract (`__dom_create_element`, `__dom_set_attr`,
`__dom_set_listener`, etc. -- documented in full in the module's own doc
comment) that a host page implements with ordinary
`document.createElement`/`setAttribute`/`addEventListener` calls. No
Counter-specific string anywhere in this file. Prop application is
generic: any `onXxx` prop whose value is a function becomes a real
`addEventListener(xxx, ...)` call (REPLACING any prior listener for that
event name on that element -- the same semantics
`hydronium.interpreter.lua`'s `hy_on_click` already established, just
generalized to every event name and every element, not one hand-found
button); every other prop becomes a real attribute via `setAttribute`
(or a boolean-attribute/`id` special case). `commitUpdate` diffs old vs.
new props and re-applies -- this diff, not `RefreshRegistry`, not any
HMR-specific code, is the entire mechanism by which an edited `onClick`
body takes effect across a refresh (verified live, see Part V).

Also added: `host.hydrateProps(handle, props)`, used only during
hydration (Part IV) to attach event listeners to a claimed pre-existing
element (real SSR HTML has attributes but never JS listeners).

## Part IV — General hydration (new: `Reconciler:hydrate`/`:hydrateRoot`)

Before this round, `core/reconciler.lua` had no hydration concept at
all. Added `Reconciler:hydrate(vnode, parentHostNode, domNode,
boundaryNode, parentComponent)` and `Reconciler:hydrateRoot(vnode,
containerHostNode, parentComponent)`, walking the host's own existing
tree structurally (element/text kind + tag matching) via five new,
optional Host methods (`firstChild`, `nextSibling`, `isElementNode`,
`isTextNode`, `tagOf`) plus an optional `hydrationMismatch(details)`
hook -- not a second DOM-patching mechanism, a real code path through
the same `mount`/`createInstance`/etc. the ordinary path already uses
whenever a match fails.

**On any mismatch** (wrong tag, ran out of real nodes, element/text kind
mismatch, or leftover real children the vnode tree never accounted
for): reports it via `hydrationMismatch` and falls back to an ordinary
`self:mount()` for that one vnode, removing the wrong pre-existing node.
Never silently claims incompatible DOM.

Both `TestHost` (for a fast native regression suite,
`tests/core/hydration_spec.lua`, 3 specs) and `hydronium.host.dom` (for
the real browser proof, Part V) implement these five methods --
`Reconciler:hydrate` itself is host-agnostic, exactly like `:mount`.

**A real, known limitation, not hidden**: the hydration walk matches
child nodes positionally and is sensitive to insignificant whitespace
text nodes a real SSR HTML string can contain between tags (e.g. pretty-
printed markup with newlines/indentation between elements) -- an
un-accounted-for whitespace text node reads as a genuine mismatch today.
This is the same constraint real frameworks like React also impose on
their own SSR output (and document as a hydration-mismatch source) --
not treated here as a bug worth hiding, but a real, present constraint
on what this session's SSR-emitting code must produce (no gratuitous
inter-tag whitespace) until/unless a future pass teaches the hydration
walk to skip whitespace-only text nodes deliberately.

## Part V — Real browser proof: arbitrary tree, real DOM, real events, real HMR

`examples/meteorite_ssr/hmr_demo/dom_host_proof.html` +
`hmr_demo/arbitrary_tree_counter.lua`, driven by Playwright/Chromium.
Real WASM Lua VM, real `hydronium.host.dom`, real
`ComponentInstance`/`Reconciler`/`Family`/`family_loader` -- the same
production code path any Hydronium app would use, not a second one
built for this proof. Tree: `<div id="app-root">` containing a real
`<header>`, two independent `Counter` component instances (each
rendering a real `<button>` via `d.button`), a `<div>`, and a
`<footer>` -- five real DOM nodes, not one hand-wired island.

**22/22 assertions passed, all against real
`document.getElementById(...)` reads, real `.click()` calls, and real
`===` object-identity comparisons** (not TestHost log entries):

1. Hydration claimed the entire pre-built tree with **zero** new DOM
   nodes created and zero mismatches (`window.__createCount === 0`).
2. Real click events on real `<button>` elements drove state through
   the ordinary event-prop path: 2 clicks -> `Count: 12`; a second,
   independent instance, 1 click -> `Count: 37`.
3. A real disk edit to `arbitrary_tree_counter.lua` (`+ 1` -> `+ 2`),
   picked up by the same already-proven `/__hydronium/watch` dev
   transport, drove `family_loader.reload()` -- reported
   `refreshed: 2, failed: 0`.
4. **DOM node identity preserved across HMR for all five real nodes**,
   captured via `document.getElementById(...) === capturedBefore`:
   Header, Footer, Profile div (untouched -- ordinary reconciliation,
   not a rebuild), AND both Counter buttons (structurally compatible,
   so reused via `commitUpdate`, not remounted) -- proves normal
   reconciliation is what's happening, not a hidden full-tree replace.
5. State preserved immediately post-refresh (12 and 37, unchanged),
   then one more real click on each: both moved by exactly +2 (the new
   logic), independently, and NEITHER moved by +3 -- proving the old
   `+1` listener was actually replaced, not left attached alongside the
   new one (`commitUpdate`'s REPLACE semantics, verified, not assumed).
6. A separate, real hydration-mismatch fixture in the same page: a
   real pre-existing `<div id="wrong-node">` where the vnode tree
   expects a `<button>` -- the fallback path created a real new
   `<button>` (plus its real text child) in the live DOM, removed the
   real wrong `<div>` from the live DOM, and reported the mismatch via
   `hydrationMismatch` -- verified via `document.getElementById(...)`
   returning `null` for the removed node afterward.

## What this does NOT do (unchanged scope boundaries, restated honestly)

- No client-side router / SPA navigation. Out of scope for this pass
  (see the separate, parallel "Hydronium Ink" terminal-host effort for
  where the next host-adapter work is going instead).
- No compiler-emitted component/module identity, no module dependency
  graph, no propagation from a changed non-component module, no
  incompatible-change/remount classification, no environment
  separation -- all unchanged from `docs/HMR_GENERALIZATION_RESULTS.md`,
  not touched by this round.
- The hydration walk's whitespace sensitivity (Part IV) is real and
  present, not fixed here.
- `ComponentInstance:mount`'s ErrorBoundary-fallback-remount branch has
  no hydration-time equivalent (`ComponentInstance:hydrate` doesn't
  replicate it) -- a hydration-time render failure isn't handled beyond
  whatever `self:render()`'s own existing error handling already does.

## Concrete gap list toward a real, reusable client-SPA API (tracked as H1-H8)

A later audit of "what would it take to go from this proof to a real
app importing a real API" produced this list. Status as of the most
recent pass:

| ID | Gap | Status |
|---|---|---|
| H1 | `src/hydronium/client/dom_bridge.js` -- the `__dom_*` bridge as a real, versioned module | **CLOSED** -- see `docs/HYDRONIUM_CLIENT_MOUNT.md` |
| H2 | Native tests for `host/dom.lua` against a fake bridge, + a checked-in browser proof | **CLOSED** -- `tests/host/dom_spec.lua` (15 specs) natively; the browser proof (`dom_host_proof.html` / `client_mount_demo/`) remains Playwright-driven, not yet wired into any automated CI step |
| H3 | A real Lua/`.luax` module bundler emitting the `package.preload` map | **NOT CLOSED** -- `tools/gen_client_manifest.lua` derives the real module LIST from the real require graph (closing the "no manual source list" half), but ships zero modules bundled: `mount.js` fetches each one as a separate real HTTP request, no amalgamation/minification/build step exists (`docs/BUNDLING.md`'s own spec, still unimplemented) |
| H4 | `hydronium.client.mount(rootComponent, containerSelector)` -- one JS entry that boots wasmoon, installs the bridge, loads the bundle, creates the host, mounts/hydrates | **CLOSED** (mount path) -- `src/hydronium/client/mount.js`, verified live: 25 real HTTP requests, real initial props, real click-driven state. Hydrate path exists (same code, `hydrate: true`) but not yet exercised end-to-end through `mount.js` specifically (see `docs/HYDRONIUM_CLIENT_MOUNT.md`) |
| H5 | A client path for `kind == ISLAND` so `d.lua.mount` stops being a documented lie | **CLOSED** -- `core/reconciler.lua`'s `isTransparentLuaIsland` handling; native proof `tests/core/lua_mount_spec.lua` |
| H6 | `src/hydronium/host/init.lua` + a `host`/`client` key on `hydronium/init.lua`; injected bridge with a "no DOM bridge installed" diagnostic | **PARTIALLY CLOSED** -- the injected-bridge + clear-diagnostic half is done (`createDomHost(bridge)`'s eager validation); `require("hydronium.host")` as a namespace and a `hydronium/init.lua` client-facing key still don't exist (only `require("hydronium.host.dom")` works) |
| H7 | SSR &rarr; hydrate round-trip proof (render with `render_to_string`, serve, hydrate the same tree) | **NOT CLOSED** -- unattempted this pass |
| H8 | `hydronium.router` -- pushState, link interception, route matching | **NOT CLOSED** -- nothing exists |
