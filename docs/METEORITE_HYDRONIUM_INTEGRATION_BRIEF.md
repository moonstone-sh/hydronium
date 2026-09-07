# Meteorite ↔ Hydronium Integration Brief (Ground Truth)

**Status: this document replaces a prior version that described an
architecture — an embedded-in-Zig-host "Model A In-Process Hybrid" with
"0.2–0.5 ms" latency and "zero IPC serialization" — that does not exist
anywhere in either repository.** Everything below was verified by reading
Meteorite's actual Zig/Lua source, running its real `meteorite invoke` CLI
against Hydronium's real SSR renderer, and running the example's live HTTP
server and curling it. Audit date: 2026-09-06.

---

## 1. What was actually being claimed, and why it was wrong

The prior brief's diagram showed Meteorite's Zig networking core directly
embedding a LuaJIT state containing "Meteorite Router / Hydronium SSR
Engine / Component Trees," with a "Performance & Telemetry Validation"
section citing "0.35 ms" render latency "tested using
`examples/meteorite_ssr/app.lua`" and comparing favorably to Node.js/V8 SSR.

None of this is real:

- `examples/meteorite_ssr/app.lua`'s "telemetry" loop never calls
  Meteorite's router at all. It manually scans `app.routes` for
  `r.raw_path == req_info.path` and calls the handler function directly
  with a hand-built mock context (`app.lua:189-210`). The test requests it
  times use the **literal route pattern string** as the request path (e.g.
  `path = "/packages/:id"`, not a real URL like `/packages/foo`), which is
  why the naive string-equality "router" appears to work at all.
- The one artifact that *does* produce real HTTP responses,
  `examples/meteorite_ssr/server.py`, is a Python `http.server` that
  **spawns a brand-new `moon exec lua` OS process for every single HTTP
  request** (`server.py:44-56`, shelling out to `meteorite invoke`) — the
  opposite of "in-process, zero IPC."
- Two of the four demo routes were **functionally broken**: the
  dynamic-params card (`/packages/:name`) and the ErrorBoundary demo
  (`/error-test`) silently dropped their content, because
  `examples/meteorite_ssr/views/App.luax` never rendered `props.children`.
  Reproduced live over real HTTP with `curl`. **Fixed this session** — see
  §6.
- Neither `tests/server/meteorite_spec.lua` nor
  `tests/meteorite/meteorite_integration_spec.lua` ever `require("meteorite")`
  — both test Hydronium's own adapter against a hand-rolled mock context
  table, never the real package.
- `moonstone.toml`/`moonstone.lock` declare no dependency on
  `moonstone/meteorite`; nothing is vendored in `.moonstone/`. The examples
  only work because `../meteorite` happens to be a sibling checkout on this
  machine, reached via hardcoded relative `package.path` entries.

The companion "compliance" doc,
`docs/HYDRONIUM_SSR_VERTICAL_SLICE_COMPLIANCE.md`, repeated these same
numbers under a "Final Verdict: APPROVED FOR PRODUCTION RELEASE (GO)"
header — see that file's own correction notice.

**What is real**: `meteorite invoke` (Meteorite's dev-mode CLI request
simulator) does perform genuine route matching, query parsing, and handler
dispatch against the real `meteorite` package (verified: `require("meteorite")`
succeeds and returns a real `app` object with a working `:get` method). The
shape the Hydronium adapter (`src/hydronium/server/meteorite.lua`) expects
from a Meteorite `ctx` (`params`, `query`, `c:html`/`c:json`) does genuinely
match real Meteorite's documented context API. The failure was specifically
in the *examples and their performance claims*, not in the adapter's own
shape assumptions.

## 2. Meteorite's real architecture (verified from `src/` and `zig/`)

| Question | Answer | Evidence |
|---|---|---|
| Route declaration | Lua DSL, positional (`app:get(path, opts, handler)`) or canonical table form (`app:get({route=..., pipeline=...})`) | `src/core/app.lua`, `src/core/route.lua`, `src/core/contract.lua` |
| Handler signature | `function(ctx) ... end`, or a Zig-symbol string, or `{kind="lua", path=...}` | `src/core/contract.lua:100` (`MeteoriteHandler` alias) |
| Response contract | **Return** a string/table, or **push** via `ctx:text/json/bytes(...)` during the call | `zig/bridge/lua_response.zig`, `zig/bridge/lua_bindings.zig:255-262` |
| **Streaming** | **Not implemented, and chunked *requests* are actively rejected** (`501 unsupported`) | `zig/server/request_enforcement.zig:43-45`, `zig/backends/fast_http.zig:186-189` |
| Response body materialization | Always a single, fully-buffered `[]const u8`, written once via `commitResponse()` | `zig/meteorite.zig:359-366`, `zig/server/context_response.zig:66-72` |
| Backpressure | None — only connection-admission backpressure (dropping new connections under load), no per-response flow control (nothing to flow-control since nothing streams) | `zig/backends/protocol.zig:236-240` |
| Async/coroutines | None. `grep -rn coroutine src/ zig/` → zero hits. One blocking `pcall` per request. | `zig/bridge/hybrid_runtime.zig:73` |
| Request context lifetime | A Zig stack-local `Context` per request; cleanup is stack unwind, no explicit teardown hook API | `zig/meteorite.zig:223-233, 359` |
| Lua VM isolation | **Depends on build profile**: fresh `lua_State` per request (default hybrid), or a `threadlocal`-cached VM shared across requests on the same worker thread (the "optimized" profile) — cross-request state leakage is a *documented, intentionally tested* characteristic of that profile | `zig/bridge/hybrid_runtime.zig` vs `zig/bridge/cached_runtime.zig`; fixtures named `lua-global-counter`, `lua-state-leak`, `lua-shared-store` in `fixtures/apps/bench-service/src/app.lua:478-499` |
| Error propagation | A Lua error is `pcall`'d, converted to a Zig error, caught again, turned into a real HTTP 500. Does not crash the process. | `zig/bridge/hybrid_runtime.zig:73-78`, `zig/server/route_execution.zig:47-64,122-125` |
| Middleware | **Real and working**: scope plugins (`m.plugin({...})` + `app:use`/`app:mount`) can inspect/short-circuit a request before the handler runs | `src/core/app.lua:273-311`, `zig/server/route_execution.zig:19-45` |
| Middleware (pipeline hooks) | **Declared, validated at build time, but dead at request time for Lua handlers** — `ctx:hook(phase, {strat="lua", ...})` is silently skipped; only `strat="zig"` hooks execute | `zig/server/route_execution.zig:85-120` (only `.zig` branch reads `.hook` stages) |
| Header commitment | Headers and body are always written together in one `commitResponse()` call; no standalone "set a header now" binding is exposed to Lua | `zig/server/context_response.zig:55-72` |
| Cancellation/disconnect | **Not implemented.** No disconnect detection, no cancellation token surfaced to Lua. | grep of `zig/` for disconnect/`BrokenPipe`/`ConnectionReset` → zero hits |

**The single fact that matters most for the integration decision**: Meteorite
has no streaming primitive at any layer — not in the Lua DSL, not in the
Zig response API, not on the wire. A Hydronium server component tree must be
fully rendered to a complete string before any `ctx` response method is
called; there is no way to flush a `<head>` early and stream `<body>` chunks
later against Meteorite's current architecture.

## 3. What Hydronium's server renderer already provides (verified from `src/hydronium/server/`)

- `server.render_to_string(vnode)` — synchronous, returns a complete string.
- `server.render(vnode, sink)` / `server.render_to_stream(vnode, opts)` —
  already sink/callback-based internally (a real, if currently
  synchronous-underneath, generic output contract independent of any HTTP
  framework).
- `hydronium.server` never `require`s `meteorite`. Its only "meteorite"
  reference is a **lazy proxy** to its own adapter module
  (`server.meteorite = setmetatable({}, {__index = function(_,k) return
  require("hydronium.server.meteorite")[k] end})`, `init.lua:454-459`) —
  confirmed by loading `hydronium.server` with `package.path` restricted to
  `src/` only (no external `meteorite` on the path at all): it loads and
  renders correctly.
- `src/hydronium/server/meteorite.lua` (the adapter) never `require`s the
  external `meteorite` package either — it duck-types the `ctx` object it's
  given (`params`, `query`, `c:html`), so it works with any object of that
  shape, real Meteorite or not.

This confirms the mission's core principle is *already true of the current
code*: Hydronium's SSR engine is independent of Meteorite, and Meteorite
integration is a thin, swappable adapter layer on top, not something baked
into `hydronium.server`.

## 4. Integration readiness verdict (updated 2026-09-07 — see §7)

**Superseded.** As of 2026-09-07 both models below are real, built, and
verified end-to-end against a compiled Meteorite binary — see §7. The
verdict below is kept for its own historical record of what was true when
written (2026-09-06):

**READY WITH SMALL ADAPTER — for a fully-buffered response model only
(Model A), at the time this was written.** Meteorite's real, current
architecture cannot support anything else:

- **Model A** (`return server.render_to_string(<Page/>)`, or
  `ctx:html(200, html_string)` / `ctx:text(200, html_string, {content_type=...})`)
  is the **only** model actually compatible with Meteorite today. It maps
  directly onto Meteorite's real response contract (return a value, or push
  once via `ctx:text/json/bytes`) and requires zero changes to Meteorite.
- **Models B/C/D** (a Hydronium response/body abstraction Meteorite
  understands natively, a streaming sink Meteorite exposes, or an
  iterator/coroutine body stream) — **FOUNDATIONAL CHANGES NEEDED on
  Meteorite's side.** There is no streaming response primitive to adapt to;
  building one would mean adding chunked/streaming support to Meteorite's
  Zig backends first (`fast_http.zig`, `std_http.zig`, `unix_socket_http.zig`
  all currently compute `content-length` from a fully-materialized body).

This is not a Hydronium limitation — `hydronium.server`'s sink-based
internals do not preclude adding real streaming later. It is that Meteorite
itself has nothing to stream into yet.

## 5. Unresolved questions for Meteorite's owner (per the mission's guidance: only asking what code doesn't already answer)

1. Is streaming response support intended as a first-class future
   contract, or is Meteorite deliberately scoped to buffered
   request/response only (matching its "release compiler contract," which
   explicitly excludes connection-upgrade/long-lived-stream contracts —
   `src/core/app.lua:198-207`)?
2. Given pipeline `ctx:hook(..., strat="lua")` is validated at build time
   but never executed at request time (§2 above) — is this a known,
   intentional gap (Lua-strategy hooks aren't supported yet, only
   `strat="zig"` ones are), or a genuine bug? This matters for anyone
   wanting to intercept/observe SSR requests via the hook mechanism rather
   than scope plugins.
3. Given the "optimized"/cached Lua-VM-reuse profile shares interpreter
   state across requests on a worker thread — does Hydronium's SSR renderer
   need to explicitly reset any module-level state between requests to be
   safe under that profile (its own render path appears stateless per call,
   but this hasn't been stress-tested under that specific profile)?

## 6. What changed in this session

- Fixed `examples/meteorite_ssr/views/App.luax` to render `props.children`
  — this alone fixes both previously-broken routes (verified: the
  `/packages/:name` "Version" card and the `/error-test` ErrorBoundary
  fallback content both now render correctly, checked directly against
  Hydronium's compile+render pipeline).
- Removed a fabricated `"Render Latency: < 0.40 ms per request"` string that
  was hardcoded directly into the rendered page content (not just the
  docs).
- Softened the page's "Model A In-Process Hybrid" badge, which implied the
  debunked embedded-Zig-host performance story, to accurately describe what
  actually executes (`meteorite invoke`, fully-buffered response).
- This document and `docs/HYDRONIUM_SSR_VERTICAL_SLICE_COMPLIANCE.md` were
  corrected/rewritten to remove the fabricated performance and integration
  claims.
- Did not modify the Meteorite repository itself — no changes were
  foundational to Meteorite; everything above is Hydronium-side.

## 7. Update (2026-09-07): real compiled Meteorite SSR, buffered and streaming, verified end-to-end

Both Model A (buffered) and the previously-declared-impossible streaming
model are now real, in `examples/meteorite_ssr`, which is a genuine
compiled Meteorite service — not `meteorite invoke`, not a Python
subprocess bridge (`server.py` is now dead — kept only for historical
reference; delete it once nobody needs the comparison).

**What changed, on both sides of the boundary:**

- **Meteorite** (separate session, same day): the hybrid-mode Lua runtime
  build bug was root-caused and fixed (`fixtures/apps/basic-service` had a
  stale hand-written `build.zig`/`main.zig` bypassing the framework's real
  `meteorite.addService` build path, plus a wrong default `lua_root`).
  `-Dmode=release-hybrid` now actually works. See Meteorite's own repo for
  details; this is the change that unblocked everything below.
- **This example** (`examples/meteorite_ssr`) now has its own
  `moonstone.toml` (`moonstone/meteorite` as a `path:` dependency,
  mirroring `fixtures/apps/basic-service`) and `build.zig` (same
  `meteorite.addService` wrapper). Hydronium itself is not a moonstone
  registry package yet, so `src/hydronium` is a plain symlink to
  `../../../src/hydronium` — the real source tree, not a copy. Build with:
  ```
  moon sync
  moon exec -- zig build -Dmode=release-hybrid -Dbackend=std_http
  ./dist/server
  ```
- **`hydronium.server.meteorite`** gained `make_stream_sink(status,
  content_type)` (a real sink backed by Meteorite's `stream_begin` /
  `stream_write` / `stream_end` globals) and `stream_handler(...)` (a
  convenience factory — see the caveat below on why it's unusable for a
  *compiled* route).

**Two real bugs found and fixed by actually compiling this, that no amount
of code reading would have caught:**

1. **Meteorite's hybrid inline-handler "source lifting" is incompatible
   with factory-returned closures.** Meteorite's hybrid build extracts
   each inline Lua route handler's own source text and reloads it
   standalone per request; a handler that closes over an upvalue from
   outside its own body fails the build (`inline Lua handler captures
   outer local`). `meteorite_adapter.handler(...)` /
   `.stream_handler(...)` are factories — they return exactly such a
   closure. **Fix:** every route in `examples/meteorite_ssr/src/main.lua`
   is now a self-contained `function(c) ... end` literal that does its own
   `require(...)` and calls `.render`/`.render_stream`/`.make_stream_sink`
   directly; `views/App.lua` exists so the compiled `.luax` component is
   `require`-able (a plain call, unlike a captured upvalue) instead of a
   `main.lua`-level local. `.handler`/`.stream_handler` remain in the
   adapter (documented with this caveat) for non-lifted integration paths
   like CLI dev/invoke mode.
2. **`meteorite_adapter.render`'s buffered fallback put `content-type`
   inside the `headers` table**, which Meteorite's real response-table
   protocol rejects (`content-type`/`content-length`/`connection`/`date`/
   `transfer-encoding` are reserved and must not appear in `headers`; the
   separate top-level `content_type` field is the only sanctioned place).
   Every prior "verification" of buffered SSR used a mock context or
   `meteorite invoke`, neither of which exercises this exact code path
   against real response-table validation — the bug was silent until a
   real compiled binary rejected it with `ReservedResponseHeader`. Fixed
   by dropping `content-type` from the `headers` table.
3. **`l_stream_begin` (Meteorite-side, `zig/bridge/lua_bindings.zig`)
   never called `lua_vtable.markResponded()`**, so after a streamed
   handler returned, Meteorite's dispatch loop — seeing no recorded
   response — sent a second, stray response on the same connection after
   the chunked terminator. Fixed same-day in Meteorite's repo.

**Verified live, raw socket, no mocks** (`GET /` and `GET
/packages/:name`): 200, correct HTML, real request ID from Meteorite's
context threaded through `useContext(RequestContext)`. `GET /error-test`:
500 with the ErrorBoundary-caught fallback content (that route
deliberately reports 500 — the catch itself is the point).

**`GET /stream`** (`socket.create_connection` + timestamped `recv()`,
against the compiled binary): the full page shell — head, styles, nav,
hero, both telemetry cards, i.e. real Hydronium `render_node` output, not
a toy string — arrives in ~15 real HTTP/1.1 chunks at t=0.014s. Then a
"Live Package Feed" section renders five rows, each preceded by a
deliberate `os.execute("sleep 0.4")` (simulating a slow per-item lookup —
not a claim about Hydronium's own render speed), and each row's `<li>`
arrives on the wire at t≈0.42s, 0.84s, 1.26s, 1.68s, 2.10s — one real HTTP
chunk per row, spaced by the simulated per-row delay. This is the same
`server.render` tree-walk as the buffered routes; only the sink (Meteorite
chunked-stream globals vs. a string-collecting closure) differs.

**What this proves, precisely:** Hydronium's existing sink contract
(`hydronium.server.render(vnode, sink, opts)`) needed zero changes to
drive real, incremental, per-node HTTP delivery once Meteorite had a real
streaming primitive to hand it — exactly the "small contract, not a
rearchitecture" finding from `METEORITE_STREAMING_FOUNDATION.md`, now
closed out with a live end-to-end proof instead of a blocked one.

**What this does NOT prove / still open:** no client hydration exists yet
(this is pure SSR, no client JS ships); no Suspense-like mechanism exists
in Hydronium to *usefully* defer part of a tree pending real async work —
the "slowness" in `/stream` is a hand-placed `os.execute("sleep 0.4")`
inside a synchronous component, not a general async/streaming-boundary
primitive. `stream_handler`/`.handler` factories are real but only usable
outside Meteorite's hybrid-lifted inline-handler path (e.g., CLI
dev/invoke, or a Zig-declared handler that calls into a Lua module
function by name rather than an inline closure — not attempted this
session). Per-request Lua state (`hybrid_profile = "default"`, used here)
means `require("hydronium")` and `require("views.App")` (which recompiles
the `.luax` source) re-run on every request; `hybrid_profile = "optimized"`
would amortize this across requests on a worker thread but was not
benchmarked this session.
