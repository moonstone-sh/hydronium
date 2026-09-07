# Hydronium Islands, Suspense, and Client Plan -- v1 Ground Truth

This document answers, with evidence, one question: of the ~70-invariant
architecture described in the "Unify `d.<interpreter>.island`, Streaming
Suspense, Progressive Hydration" mission brief, what is actually
implemented and verified today (2026-09-07), and what is still just the
brief's own design language? Before this session, `grep -rli
"island|suspense|resource(" src/` returned **zero matches** anywhere in
Hydronium -- the brief's framing that this combines with "the
already-established Hydronium direction for... Suspense... async
Resources... hydration... partial hydration" was aspirational, not a
description of existing code, for all of those except SSR/streaming
(which a separate session had already built and verified against a real
compiled Meteorite binary -- see `METEORITE_HYDRONIUM_INTEGRATION_BRIEF.md`).

This session implements a deliberately narrow slice of that brief: Part
XXII's own recommended steps 1-3 (semantic contracts; `d.lua.island` /
`d.js.island` descriptors and typing; buffered SSR emitting island markers
and a deterministic client plan), plus a real (non-streaming) Suspense/
Resource model, because the brief's own Part III insists Suspense and
Island are orthogonal and testing one without the other would be
incomplete. Steps 4 onward -- an actual Lua WASM client runtime, a JS
bridge, out-of-order streaming Suspense replacement, hydration policies
beyond a string label, tree-shaking -- are **not attempted**. Every claim
below was verified by running real code (`luajit tests/runner.lua`, and a
real compiled Meteorite binary over real HTTP), not by reading the brief
and agreeing with it.

## What is real, today, verified

1. **`d.lua.island`, `d.js.island`, `d.js.script`, `d.lua.mount`**
   (`src/hydronium/dom/init.lua`) are ordinary, immutable, callable
   descriptor tables -- `<d.lua.island>` is plain LUAX lexical tag
   resolution (`(d.lua).island`, then a normal call), exactly like
   `<d.button>`. **Zero grammar changes** anywhere in
   `src/hydronium/luax/` -- confirmed by grep and by the existing LUAX
   corpus tests (which already cover arbitrary dotted tag expressions)
   continuing to pass unmodified. Importing `hydronium.dom` does not
   reference `hydronium.interpreter.lua`/`.js` at all -- those packages do
   not exist yet, and nothing in `dom/init.lua` requires them.
2. **A new `symbols.ISLAND_DESCRIPTOR` / `symbols.SCRIPT_DESCRIPTOR`**
   distinguish island/script descriptors from ordinary
   `symbols.INTRINSIC` HTML tags, so `d.lua` can never be mistaken for a
   fake `<lua>` element. `createElement` (`core/element.lua`) dispatches
   them to new `symbols.ISLAND` / `symbols.SCRIPT` VNode kinds, keeping
   the full descriptor (interpreter, module, mode) on the vnode rather
   than unwrapping to a bare string the way INTRINSIC does.
3. **`h.Suspense`** (`core/suspense.lua`) and **`h.resource`**
   (`core/resource.lua`) exist, exported from both `hydronium.core` and
   the top-level `hydronium` module. Three resource states --
   `"pending"`, `"ready"`, `"failed"` -- never conflated.
4. **SSR (buffered) island rendering** (`server/init.lua`): a
   `d.lua.island`/`d.js.island` subtree renders its children normally,
   wrapped in stable, deterministic, tree-order-derived HTML comment
   markers (`<!--hy:i:<id>:<interpreter>--> ... <!--hy:/i:<id>-->`) --
   never a pointer, random value, or timestamp. An island entry (id,
   interpreter, module, mode, hydrate policy, props) is recorded in a
   `ClientPlan` (`{version = "hydronium.client-plan.v1", islands, scripts}`)
   accumulated per render call. `render_to_string` returns it as a second
   value; `render`/`render_stream`'s `on_complete` receives it. When the
   plan is non-empty, a `<script id="__HYDRONIUM_CLIENT_PLAN__"
   type="application/json">` tag is appended (opt out with
   `suppress_client_plan_script = true`, mirroring the existing
   `suppress_state_script`) -- an SSR-only page with no islands/scripts
   emits no such tag at all.
5. **`d.js.script`** renders no DOM element of its own -- it only
   contributes a `Script` record to the client plan (`src`, `module`
   when `type="module"`, `strategy`, `integrity`, `binds`).
6. **Suspense (v1: sequential/buffered only)**: a Suspense boundary
   renders its children into an *isolated internal buffer* (the same
   proven trick `ErrorBoundary` already used for its own fallback
   isolation) and either flushes the whole buffer on success or discards
   it and renders `fallback` if a descendant `Resource:get()` suspends --
   so a suspension partway through a boundary's subtree never leaks
   partial bytes to the real sink, verified by a dedicated test
   (`tests/server/islands_suspense_spec.lua`, "does not leak partial
   output from a subtree that ends up suspending").
7. **Two, and only two, ways a Resource is pending**, both real and
   tested: (a) `resource.new(loader)` -- `:get()` runs the loader
   synchronously (blocking) on first call and never actually suspends;
   this is the "sequential" mode the mission's own Part V §24 explicitly
   sanctions, and it means **no fallback is ever visibly rendered for a
   loader-backed resource** -- by design, matching a plain blocking Lua
   call. (b) `resource.new()` (no loader) -- `:get()` always suspends
   until something external calls `:resolve(value)`/`:reject(err)`; this
   is the shape that actually exercises `fallback`, and the example route
   below deliberately leaves one permanently pending to prove the
   fallback path itself renders correctly, independent of ever resolving.
8. **Suspense and ErrorBoundary are verified orthogonal, not just
   documented as such**: a suspension signal (`error({__hydronium_suspension
   = true, ...})`) passing through an `ErrorBoundary` with no intervening
   `Suspense` is explicitly re-raised unchanged (not treated as a caught
   render error) -- tested. A resource that *fails* (loader errors) is
   caught by the nearest `ErrorBoundary`, never by `Suspense` -- tested.
   A resource left pending with **no** enclosing `Suspense` at all raises
   a distinct, clear top-level error ("a Resource was read while pending
   with no enclosing `<h.Suspense>` boundary...") rather than leaking the
   raw internal suspension table to `on_error`/callers -- this is the
   "root suspension policy must be defined explicitly" invariant, and the
   explicit policy chosen is: **error, don't guess**.
9. **Lua event callbacks are never serialized into HTML** -- verified
   pre-existing behavior in `html.lua`'s attribute filter (function-valued
   props were already excluded, unrelated to this session). **New this
   session**: a Lua function on a camelCase event-shaped prop (`onClick`,
   `onInput`, ...) with **no** enclosing `d.lua.island`/`d.lua.mount`
   raises the exact diagnostic the mission specifies ("Lua callback
   `onClick` requires a Lua client execution boundary...") instead of
   Hydronium's previous behavior of silently dropping it. A non-camelCase
   function-valued prop (e.g. `on_change`, not matching the real DOM event
   convention) is left alone -- still silently excluded, since it isn't a
   recognized event name; only `on[A-Z]...` triggers the diagnostic.
10. **A real bug this session's own tests caught and fixed**: the first
    `d.lua`/`d.js` namespace implementation used table literals with
    pre-set keys (`{island = ..., mount = ...}`) wrapped in a metatable
    whose `__newindex` was supposed to make them immutable -- but Lua only
    invokes `__newindex` for keys *absent* as a raw entry; assigning over
    an *existing* key is a silent `rawset`, bypassing the guard entirely.
    A test that mutated `d.lua.island` to `nil` to prove immutability
    instead silently succeeded and corrupted the shared, cached `d.lua`
    module table for the rest of the same test process, cascading into
    five unrelated-looking failures. Fixed by using the same
    empty-outer-table-with-`__index`-into-a-separate-store proxy pattern
    the pre-existing `d` table already used correctly.
11. **Verified live, no mocks**, against the real compiled Meteorite
    binary from `examples/meteorite_ssr` (`GET /islands`): the response
    contains the exact `<!--hy:i:hy:i1:lua--> ... <!--hy:/i:hy:i1-->`
    markers around a real "Count: 10" render, a
    `__HYDRONIUM_CLIENT_PLAN__` script tag listing exactly one island
    (`interpreter":"lua"`, `"hydrate":"visible"`), the loader-backed
    resource's real resolved text with its fallback text verified absent,
    and the permanently-pending resource's fallback text present with its
    real (never-rendered) content verified absent.

## What this explicitly does NOT implement (mission parts intentionally deferred)

- **No `hydronium.interpreter.lua` / `.js`.** No WASM Lua runtime is
  loaded, built, or referenced. No browser was used this session (the
  Chromium extension mentioned in an earlier session was not needed for
  this SSR-only slice). `d.lua.island`'s HTML comment markers exist; the
  client-side code that would find them and hydrate anything does not.
- **No client reconciler support for Suspense/Island/Script.** Attempting
  to `mount()` (the live-DOM/test-renderer path, not SSR) a VNode with
  `kind == SUSPENSE|ISLAND|SCRIPT` now raises a clear, deliberate error
  ("has no client reconciler yet (SSR-only in this version)") rather than
  silently mounting nothing -- see `core/reconciler.lua`. This was a
  conscious choice: silently dropping an island's children client-side
  would violate the same "no silent data loss" principle as the event
  callback diagnostic.
- **No streaming Suspense.** Everything above is buffered/sequential:
  `Suspense` isolates writes in an in-memory Lua table, not a real
  chunked-transfer segment sent early and replaced later. Real Meteorite
  HTTP/1.1 chunked streaming exists (`stream_begin`/`stream_write`/
  `stream_end`, verified in a separate session) and Hydronium's sink
  contract can already drive it (`render_stream`, also verified separately
  for the non-Suspense case at `/stream`) -- but Suspense's fallback
  isolation buffer and Meteorite's live chunked sink have not been
  connected. Out-of-order segment replacement, stable per-boundary
  streaming IDs distinct from island IDs, and a client-side patcher do not
  exist.
- **No hydration policies beyond a stored string.** `hydrate = "visible"`
  is recorded verbatim in the client plan; nothing reads or acts on it.
  `load`/`idle`/`interaction`/`manual` are not implemented or
  distinguished at all.
- **No JS bridge, no `d.js.value`/`d.js.dom`/`d.js.callback` capability
  primitives, no foreign-module ABI.** `d.js.island`'s `module`/`props`
  are recorded in the client plan as plain data; nothing imports or calls
  a JS module.
- **No tree-shaking / demand-driven client bootstrap.** There is no
  client bootstrap to shake in the first place.
- **No hydration mismatch detection**, dev or production -- there is no
  hydration to mismatch against yet.
- **No dehydrated-resource transfer to a client.** `h.resource`'s state
  lives only in the Lua state that rendered it.
- **Root Lua mount (`d.lua.mount`) is implemented as a data shape only**
  (`{kind = ISLAND, props = {root = true}}`) -- there is no runtime that
  does anything different for a root-mounted island versus a partial one,
  since neither hydrates yet.
- **Nvim/Tree-sitter**: no new headless-Neovim completion proof was run
  this session for `<d.lua.|`/`<d.js.|` specifically (the kind done for
  bare/lexical DOM tags in an earlier session). The type declarations
  above (`types/dom/init.d.lua`, `types/hydronium.d.lua`) are real LuaCATS
  and should drive real LuaLS completion by the same mechanism already
  verified for `d.button` etc., but this was not independently
  re-verified against a live LuaLS session this time -- treat as
  INFERRED, not VERIFIED, until someone actually opens a `.luax` file and
  checks.

## Files touched

- `src/hydronium/core/symbols.lua` -- `ISLAND`, `SCRIPT`, `SUSPENSE`,
  `ISLAND_DESCRIPTOR`, `SCRIPT_DESCRIPTOR`.
- `src/hydronium/core/resource.lua`, `src/hydronium/core/suspense.lua` --
  new.
- `src/hydronium/core/element.lua` -- dispatch for the new kinds.
- `src/hydronium/core/reconciler.lua` -- explicit "not supported client-side
  yet" error instead of silent no-op mounting.
- `src/hydronium/core/init.lua`, `src/hydronium/init.lua` -- export
  `Suspense`/`resource`/`isSuspension`.
- `src/hydronium/dom/init.lua` -- `d.lua`/`d.js` namespaces.
- `src/hydronium/server/init.lua` -- island markers, client plan,
  Suspense buffering/fallback, ErrorBoundary/Suspense transparency, the
  Lua-callback-outside-boundary diagnostic.
- `tests/server/ssr_spec.lua`, `tests/server/islands_suspense_spec.lua`
  (new) -- 336/336 specs pass (`luajit tests/runner.lua`).
- `types/dom/init.d.lua`, `types/hydronium.d.lua` -- LuaCATS types.
- `examples/meteorite_ssr/src/main.lua` -- real `/islands` route,
  verified over HTTP against a real compiled Meteorite binary.
- `src/hydronium/interpreter/lua.lua` (new) -- the first
  `hydronium.interpreter.*` module: a narrow, real Counter-island
  hydration proof (real `createSignal`/`createEffect`, real DOM claim via
  a documented host bridge contract).
- `tests/interpreter/lua_spec.lua` (new), `tests/runner.lua` (added the
  missing `assert.fail`) -- 343/343 specs pass.
- `src/hydronium/client/bootstrap.js`, `examples/js_island/counter.js`
  (new) -- the `d.js.island` module-loading bootstrap and a real example
  module, verified against a real DOM (jsdom) with zero Lua/WASM
  involvement.
- The published "Hydronium in WASM" artifact (same URL throughout) --
  now includes the full 47-file Hydronium source tree after a real bug
  (missing `luax/`, silently required by `require("hydronium")`) was
  caught by testing the *exact* embedded code string, not an equivalent
  substitute, and fixed before this account was written.
- `examples/meteorite_ssr/src/main.lua` -- `meteorite.site` static
  routes for the real `counter.js`/`bootstrap.js` (pointed at their
  canonical directories directly, no symlink -- Meteorite's static
  codegen rejects symlinked static directories) and a new `/mixed` route:
  the mission's "mixed" flagship case (Suspense + Lua island + JS island,
  one real compiled page, verified over real HTTP).
- `tests/luax/run_lsp_tests.py` -- 4 new real LuaLS integration checks
  (2 pass, 2 root-caused and left honestly red) for `d.lua`/`d.js`
  completion.

## Update (2026-09-07, later): step 4 attempted -- wasmoon executing real Hydronium source

Per the mission's own Part XXII sequencing, the next real, falsifiable
increment was step 4: get a Lua WASM runtime loaded and executing real
code -- *before* attempting to make `d.lua.island`'s markers mean anything
client-side. This was pushed further than "one Lua expression": the
actual, unmodified `hydronium.core.element` (plus its transitive
dependencies `symbols.lua`/`errors.lua`/`suspense.lua`) was mounted into
`wasmoon` (a real Lua 5.4-in-WebAssembly interpreter) and its real
`createElement()` was called.

**Verified directly, in Node.js, with `console.log` output actually
inspected** (`npm install wasmoon`, `LuaFactory.mountFile` for each of the
four real source files read straight off disk, `package.path` set, then
`require("hydronium.core.element")`):

```
Lua _VERSION: Lua 5.4
REAL Hydronium createElement() executed inside WASM Lua:
  tag=div kind=ELEMENT typeof=VNODE class=counter
  children[1]=VNode(Hydronium.Symbol(TEXT)) #children=1
```

Real Lua 5.4 (confirmed via `_VERSION` and via error messages matching
Lua's exact `[string "..."]:1: msg` format, not a JS shim), real closures
and upvalues (a counter closure survived two `increment()` calls), and a
real VNode returned by the actual framework code -- including the child
string correctly promoted to a real Text VNode, framework behavior not
something this test hand-coded.

**Also built, published, NOT independently verified by this session**: a
self-contained browser page (a Claude Artifact) doing the same proof
live -- wasmoon loaded as an ES module from jsdelivr (the one CDN host
artifacts may load scripts from), with the ~265KB `glue.wasm` binary and
all four Lua files embedded inline as base64 (Claude Artifacts block a
library's own runtime `fetch()` of assets from a CDN, even an allowed
one -- only the initial script load is permitted -- so the wasm binary is
passed to `LuaFactory` as a `data:` URI instead of letting wasmoon fetch
it from unpkg, its default). The page runs the same `createElement()`
proof on load and reports PASS/FAIL directly on the page (no devtools
needed), so it is self-diagnosing regardless of outcome -- but this
session has no browser-automation tool, so **whether it actually passes
in a real Chrome tab is unconfirmed** pending the user opening the link.
The `data:` URI approach could not be validated from Node either: Node's
Emscripten glue loads a custom WASM URI via `fs.readFileSync` and treats
a `data:` string as a (too-long) file path, which is a Node-specific
code path, not evidence about how a real browser's `fetch()` (which does
support `data:` URIs) will behave.

This closes the core technical risk the mission worried about --
does Hydronium's real Lua code run inside a WASM Lua VM at all -- with
hard, falsifiable evidence, while being explicit that "in a real browser
tab" specifically still needs the user's own confirmation.

## Update (2026-09-07, later still): the actual Counter hydration proof, not just one expression

Went past "one Lua expression" to the mission's literally-named milestone
(Part XXVII/§42, "First Lua proof"): a real `hydronium.interpreter.lua`
module now exists (`src/hydronium/interpreter/lua.lua`) -- the first code
in `hydronium.interpreter.*` at all. Deliberately narrow, by design (its
own doc comment says so): `hydrate_counter_island(island_id, initial)`
claims exactly the DOM shape one `<d.lua.island><Counter/></d.lua.island>`
SSR boundary produces, wires a real `hydronium.signals.createSignal` +
`createEffect` to it, and attaches one real click listener. It is a proof
this milestone is real, not a general hydration algorithm -- building
that ahead of a second, differently-shaped proof would be exactly the
speculative work this project avoids (see the module's own header comment
for the explicit scope note, and `core/reconciler.lua`'s new explicit
error for ISLAND/SUSPENSE/SCRIPT-kind vnodes: mounting these client-side
through the general reconciler is still unimplemented on purpose, not
silently unsupported).

**Verified in three independent, non-overlapping ways, each catching a
real bug the others could not have:**

1. **Real Hydronium signals + real async JS&rarr;Lua callback, in real
   WASM Lua (Node/wasmoon, no DOM at all)**: a fake plain-JS-object stood
   in for the DOM so this test isolates "does an asynchronously-invoked
   Lua closure correctly re-enter the VM after the original call
   returned" (the part most likely to be fragile in a WASM FFI) from real
   DOM API behavior. Passed: `hydrate_counter_island(10)` rendered
   `"Count: 10"`, a click fired *later*, from JS, asynchronously, correctly
   advanced the real Lua-side signal to 11 and re-ran the real
   `createEffect`, twice in a row.
2. **The exact DOM bridge JS this proof ships, against a real DOM
   implementation (jsdom), no WASM/Lua at all**: mounted the *actual* SSR
   HTML shape `server/init.lua`'s ISLAND handling produces (comment
   markers plus a trailing `__HYDRONIUM_CLIENT_PLAN__` script tag) and
   confirmed `TreeWalker`+`SHOW_COMMENT` finds the exact markers, the
   located button is reference-identical (`===`) to what `querySelector`
   finds, and a **real dispatched `click` `Event`** (not a direct function
   call) drives the DOM update correctly and doesn't get confused by the
   trailing script tag.
3. **A LuaJIT spec** (`tests/interpreter/lua_spec.lua`, 7 tests, part of
   the regular 343-spec suite) pinning the module's own Lua-side contract
   and diagnostics -- fast, no browser or WASM needed for this part.

**Not independently verified**: the seam between (1) and (2) -- wasmoon's
own WASM-loading code path taken specifically inside an actual browser
tab (as opposed to plain Node, which (1) used, or jsdom, which (2) used).
An attempt to test this exact seam via Node+jsdom+wasmoon together failed
with a `new URL(..., "about:blank")` error that traces to jsdom's
partially-stubbed globals (`document` set manually without a real
`window`/`location`) confusing wasmoon's environment detection -- an
artifact of that specific three-way hybrid test harness, not of Node or
jsdom individually, and not informative about a real browser (where
`window`/`document`/`location` are all genuinely, consistently present).
Published (same URL as before) for the user to open and confirm.

**Update: the user opened it and it failed, with a real, informative
error** -- exactly the seam flagged above as unverified. Claude Artifacts'
CSP `connect-src` is `'self' https://fonts.googleapis.com
https://fonts.gstatic.com` -- it does not list `data:` at all, so
wasmoon's internal `fetch(dataUri)` for the wasm binary (needed because
its *default* wasm source is `https://unpkg.com/...`, not on the CDN
allowlist -- see the original reasoning above) was refused outright, even
though the bytes never leave the page. The assumption that a `data:` URI
would be exempt from a host-based CSP was simply wrong for this CSP.

**Fixed** by intercepting `window.fetch`: for that one specific
`data:application/wasm` URL only, resolve it from a `Response` object
constructed directly from the bytes already embedded in the page's own
source (`atob` + `Uint8Array`) -- constructing a `Response` object is
pure JS, touches no network layer at all, so `connect-src` (which governs
actual network requests) does not apply to it. Everything else (the
Google Fonts stylesheet) still goes through the real, unmodified `fetch`.
This is a standard technique (the same idea underlying offline-first
fetch interception, without a service worker here), not an exploit or a
CSP bypass in the security sense -- it doesn't reach anything the page
wasn't already allowed to have; it just avoids asking the network layer
to hand back bytes the page already possesses.

Two other lines in the same error report are unrelated and harmless: an
"Unrecognized Content-Security-Policy directive 'webrtc'" warning (the
browser not recognizing one CSP directive name, unrelated to WASM) and a
blocked fetch of a jsdelivr `.map` sourcemap file (DevTools' own
best-effort debug-symbol fetch for the bundled JS, blocked by the same
`connect-src`, but non-fatal -- it only affects how a stack trace displays
in DevTools, not execution). Republished (same URL) with the fix; not yet
re-confirmed working by the user as of this writing.

**A real bug this session's own testing caught**: the first version of
`tests/interpreter/lua_spec.lua` installed its fake DOM bridge as plain
`_G.hy_*` globals (matching the module's real, documented host contract)
but never cleaned them up, leaking them into `_G` for the rest of the
test process -- tripping `tests/luax/isolation_spec.lua`'s
global-namespace-pollution check for every spec file that happened to run
afterward (which itself has a smaller pre-existing bug: it calls a
`assert.fail(...)` this test framework doesn't define, so the pollution
check crashed with a confusing "attempt to call field 'fail'" instead of
a clear pollution report -- not fixed this session, flagged here since it
would otherwise mask real future leaks with a useless stack trace instead
of the intended message). Fixed by adding an `after_each` that nils the
five bridge globals.

**What this does NOT settle**: no multi-island shared-VM story (this page
has exactly one island), no Suspense-aware hydration ordering, no
hydration-mismatch detection beyond "fail loudly," no interaction/
visible/idle hydration policies -- `hydrate = "load"` is recorded and
ignored. Do not build the general hydration algorithm or streaming
Suspense replacement ahead of a proof shaped differently enough to
actually test genericity.

## Update (2026-09-07, later still): a real bug this exact process caught in the published artifact itself

Before starting the `d.js.island` proof below, a final "exact verbatim
code" check was run against the SSR+hydrate Lua string the *already
published* browser artifact embeds -- and it failed:
`hydronium/init.lua:77: module 'hydronium.luax' not found`.
`require("hydronium")` unconditionally, eagerly requires
`hydronium.luax` (the LUAX compiler) as one of its own fields -- and the
published artifact's embedded file set had deliberately excluded
`luax/` as "not needed for this proof" (153KB of Lua source, 16 files).
It was needed: not for anything the proof exercises, but because
`require("hydronium")` itself pulls it in regardless.

This was missed because verification had, until this check, always
tested *pieces* (createElement alone; `hydrate_counter_island` against a
pre-built fake island) rather than the *exact assembled code string* the
artifact ships. The artifact had never actually been proven to run start
to finish -- it was published on the strength of separately-true pieces,
which is exactly the kind of gap this project's own stated practice
(verify claims empirically, don't extrapolate from partial checks) exists
to catch. **Fixed**: the artifact's embedded file set now includes the
full 47-file Hydronium source tree (was 31, wrongly excluding `luax/`),
verified by running the *exact* Lua source string the artifact contains,
copied verbatim into a throwaway Node/wasmoon script, before republishing
(same URL). The takeaway for future changes to this proof: verify the
literal code being shipped, not an equivalent-looking substitute.

## Update (2026-09-07, later still): `d.js.island` module proof

Mission Part XXII step 5 ("JS island module proof"), and invariant #44
("JS-only islands ship no Lua WASM"). Two new real, reusable files, not
artifact-only glue:

- **`src/hydronium/client/bootstrap.js`** -- a real, dependency-free
  client bootstrap. `activate(doc, root)` reads the
  `__HYDRONIUM_CLIENT_PLAN__` script tag, and for each `interpreter:
  "js"` island: locates its DOM range via the same comment-marker
  convention already verified for the Lua proof, dynamically `import()`s
  its `module`, and calls `hydrate(context)` (default) or
  `mount(context)` (when `mode: "mount"`) with `{root, props}`.
  `interpreter: "lua"` islands are counted and skipped -- this file has
  no code path that could load Lua/WASM even by accident, which is the
  actual mechanism behind invariant #44, not just a claim about it.
  **Real design bug found while first testing this against an actual
  dynamic `import()`**: a relative `module` value like `"./chart.js"`
  resolves against *this bootstrap file's own URL*, not the page's or
  the app's asset root -- both browsers and Node do this by spec.
  Documented directly in the file: `d.js.island`'s `module` must be an
  absolute path or full URL.
- **`examples/js_island/counter.js`** -- a real, minimal `d.js.island`
  module (`hydrate`/`dispose`, no `mount`) implementing the exact same
  Counter semantics as the Lua proof, in plain JS, with zero framework
  dependency.

**Verified**: a static check (comments stripped, functional code only)
confirms neither file references `wasmoon`/`WebAssembly`/`.lua` anywhere.
Then, end to end: real `hydronium.server.render_to_string` for
`h(d.js.island, {module=<abs file url>, props={initial=10}})` (via
wasmoon, now correctly including `luax/`) produced real SSR HTML and a
real client plan with `interpreter: "js"`; that HTML plus a hand-built
matching client-plan script tag were injected into a real DOM (jsdom);
the real `bootstrap.activate()` found exactly one JS island (zero Lua
islands skipped, zero errors), dynamically imported the real
`counter.js` from disk, and called its real `hydrate()`. A real
dispatched click (twice) drove the DOM through plain
`addEventListener`/`textContent`, and `disposeIsland()` genuinely
detached the listener -- verified by a further click producing no
further change, not just by dispose() being callable without erroring.

## Update (2026-09-07, later still): the mission's "mixed" flagship case, for real

Part XXII step 11: one Suspense boundary, one Lua island, one JS island,
on the same real, compiled, HTTP-served page (`GET /mixed` on
`examples/meteorite_ssr`). This closes the "not attempted" gap from the
previous update -- `counter.js` and `bootstrap.js` are now served by
Meteorite itself, over a real socket, not just read from disk in a
Node/jsdom test.

**How the static serving is wired**: `meteorite.site(app, { assets =
{...} })`, Meteorite's own static-file route mechanism (plain routes, not
inline Lua -- works in any build mode). **Found immediately**: Meteorite's
static codegen refuses to serve a directory containing symlinks at all
(`static directory contains symlinks` -- a deliberate safety check, not a
bug). A symlinked `static/` folder mirroring the canonical
`examples/js_island/counter.js` and `src/hydronium/client/bootstrap.js`
was the first thing tried and was rejected outright. Fixed properly, not
worked around: the asset routes point directly at the real, canonical
directories (`../js_island`, `../../src/hydronium/client`) -- no local
copy, no symlink, no drift between what's served and what's real by
construction.

**Verified live, real HTTP, no mocks**: `curl` against the running
compiled binary confirms `/js/island/counter.js` and
`/js/bootstrap/bootstrap.js` return `200` with `content-type:
application/javascript; charset=utf-8` and are **byte-identical** (`diff`)
to the real source files. `GET /mixed` returns `200` with: the Suspense
boundary showing its real resolved content (`"Feed resolved
synchronously during SSR."`) and its fallback text confirmed absent; a
`d.lua.island` marker (`hy:i1:lua`) around a real `Count: 3` button; a
`d.js.island` marker (`hy:i2:js`) around a real `Count: 7` button; a
client plan listing both islands with correct `interpreter`/`module`/
`props`; and a real `<script type="module">` tag importing the real,
now-fetchable bootstrap and calling `activate()`.

**What a real browser opening this page would do, not independently
confirmed**: fetch and run the bootstrap, which finds the JS island
(module `/js/island/counter.js`, an absolute path -- the exact
constraint `bootstrap.js` documents), hydrates it for real, and correctly
does *not* touch the Lua island (this bootstrap has no code path that
could) -- the SSR markers for the Lua island exist on this page but
nothing on it hydrates that island, which is itself the point: a page
that visibly has both kinds of island only loads what its JS-only path
actually needs.

All 9 routes on this app (`/`, `/packages/:name`, `/error-test`,
`/api/health`, `/stream`, `/islands`, `/js/island/:path*`,
`/js/bootstrap/:path*`, `/mixed`) return their expected status over a
fresh `curl` sweep after this change. 343/343 Lua specs still pass.

## Update (2026-09-07, later still): real LuaLS verification -- one gap real-rooted, not papered over

Earlier updates marked `<d.lua.|`/`<d.js.|` LuaLS completion as "INFERRED,
not VERIFIED." Verified now, for real, using the project's own existing
`tests/luax/run_lsp_tests.py` harness (drives `lua-language-server`
directly over raw LSP JSON-RPC via `tests/luax/lsp_client.py` -- no
Neovim in this path, a more direct check of LuaLS itself), extended with
four new permanent checks in that same file.

**Passes**: `<d.lua.|` completion offers exactly `island`/`mount`;
`<d.js.|` completion offers exactly `island`/`script` -- confirming the
`types/dom/init.d.lua` additions drive real completion through ordinary
LuaCATS field typing, the same mechanism that already worked for
`<d.button`, with no LUAX-tooling changes needed for this half.

**Fails, and was root-caused, not left as a mystery**: prop completion
*inside* the tag (`<d.lua.island |>` / `<d.js.island |>`) falls back to
generic Lua keyword completion instead of `hydrate`/`root`/`key` (Lua) or
`module`/`mode`/`hydrate`/`props`/`binds` (JS). Investigation, in order:

1. A direct hover on the plain expression `d.lua.island` (no JSX, no
   tag) resolves *perfectly* -- LuaLS shows the exact declared union
   *and* the correctly narrowed call signature `function(props?:
   HydroniumLuaIslandProps, ...) -> LuaxElement`, identical in shape to
   `d.button`'s own resolved signature. The type declarations themselves
   are not the problem.
2. `src/hydronium/luax/luals/virtual_source.lua`'s `transform_element`
   rewrites *any* dotted JSX tag (`JSXMemberExpression`) -- one dot or
   several -- to `__luax_component(<full dotted path>, {props})` via a
   correctly-recursive `get_name()` that handles arbitrary nesting depth.
   `<d.button>` and `<d.lua.island>` go through the exact same rewrite
   shape; `is_intrinsic` is hardcoded `false` for *all* dotted tags
   either way, so that flag isn't the difference.
3. Hypothesis "LuaLS's generic inference for `__luax_component`'s
   `@generic TProps` doesn't narrow a union through a 2-level chained
   member-access expression used directly as a call argument" was tested
   directly and **disproven**: assigning `local luaIsland = d.lua.island`
   first and writing `<luaIsland |>` (a single bare-identifier tag, the
   same shape the working `is_intrinsic` `Identifier` branch or a plain
   local reference would take) *also* fails to complete `hydrate`/
   `root`/`key`. The failure is not specifically about expression depth
   at the call site.

**Conclusion, stated at the actual confidence level reached**: something
about resolving a type declared two class-hops deep (`HydroniumDOMDescriptors
.lua : HydroniumDOMLuaNamespace`, then `HydroniumDOMLuaNamespace.island`)
survives for hover/display purposes but does not survive whatever
narrower resolution path LuaLS's generic-parameter binding uses when
matching `__luax_component`'s `@generic TProps` against the argument
type -- most likely a real depth/precision limit in LuaLS's own
generic-inference engine for nested class-field chains, encountered here
for the first time because no *existing* Hydronium intrinsic was ever
declared two hops deep. This is not fully proven (LuaLS's own inference
internals were not inspected), so treat "LuaLS generic-inference depth
limit" as the best-supported hypothesis, not a certainty.

**Deliberately not "fixed" by flattening** `d.lua`/`d.js` into direct
top-level fields on `HydroniumDOMDescriptors` (which would likely sidestep
the two-hop resolution and probably restore prop completion) --
that would abandon the mission's own required `d.lua.island`/`d.js.island`
namespaced authoring surface to route around a third-party tool's
inference limit, trading a real architectural requirement for cosmetic
IDE completion. The two new prop-completion checks are left in the
permanent suite as honest, currently-red trackers (matching this file's
own pre-existing convention of keeping real failing checks rather than
deleting inconvenient ones -- see the next paragraph) rather than removed
or weakened to pass.

**A second, unrelated, pre-existing regression found while doing this**:
running the *unmodified* baseline suite before adding anything already
showed 3 failures having nothing to do with islands: `<d.button
onClick={...}>`'s `ev.currentTarget` hover resolves to `unknown` instead
of `HTMLButtonElement` (same for `<d.input onInput`/`HTMLInputElement`),
and a subsequent hover request thereafter hangs until a 5s timeout kills
the whole harness. Confirmed pre-existing (reproduces with zero changes
applied) and out of scope for islands/d.lua/d.js work -- flagged here so
it isn't mistaken for something this session's changes caused, not
investigated further.
