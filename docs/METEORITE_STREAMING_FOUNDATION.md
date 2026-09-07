# Meteorite Streaming Foundation (Ground Truth)

This document answers one question with real evidence, not architectural
prose: **is a minimal streaming response primitive in Meteorite a small,
bounded contract, or an open-ended rearchitecture?** Verified by reading
Meteorite's real Zig source and by actually writing, compiling, and
partially testing the primitive against the real codebase. Audit date:
2026-09-07.

## Verdict: SMALL CONTRACT + IMPLEMENTATION WORK, not open-ended

Evidence, not assertion:

1. **The abstraction boundary already exists and is clean.**
   `zig/server/context_response.zig` defines `Response(comptime backend,
   comptime protocol, comptime build_info)` — a single generic module
   already parameterized over the backend. `zig/bridge/lua_vtable.zig`
   defines a type-erased `VTable` (function pointers over `*anyopaque`)
   that already isolates the Lua-facing API from the concrete backend type.
   Adding a streaming primitive meant adding entries to *one* generic
   struct and *one* vtable, not touching call sites scattered through the
   codebase.

2. **All three backends already share the identical low-level write
   pattern.** `fast_http.zig`, `std_http.zig`, and `unix_socket_http.zig`
   each implement `respondBytesWithHeaders` as: build a header block into a
   fixed buffer, `req.writer.interface.writeAll(headers)`, conditionally
   `writeAll(body)`, then `.flush()`. All three already call `writeAll`
   *twice* per response (headers, then body) before finishing — meaning
   incremental writes to the same connection were never actually
   unsupported; buffered responses just never needed more than two.

3. **No coroutines needed.** Every route handler already executes as one
   blocking `pcall` per request (confirmed: zero coroutine usage anywhere
   in `src/`/`zig/`). "Streaming" here means a Lua handler calls a write
   binding multiple times *within that same synchronous call* — each call
   is a real, immediate socket write, not a suspend/resume point.

4. **Backpressure comes free.** Connections are handled with blocking
   socket I/O (`req.writer.interface.flush()` is a blocking call). Where
   backends are thread-per-connection, a slow client simply blocks that
   connection's thread at `flush()` until the OS accepts the bytes — real,
   correct TCP backpressure, not a primitive that needs to be built.

### What was actually implemented and verified this session

- `beginStream(ctx, status, content_type)`, `writeChunk(ctx, chunk)`,
  `endStream(ctx)` added to `context_response.zig`'s generic `Response(...)`
  — parallel to, and independent of, the existing buffered
  `stageBytes`/`commitResponse` path. Buffered responses are completely
  unaffected.
- Matching `beginStream`/`writeChunk`/`endStream` low-level functions added
  to **all three backends** (`fast_http.zig`, `std_http.zig`,
  `unix_socket_http.zig`), each using real HTTP/1.1 chunked
  transfer-encoding (RFC 7230 §4.1) over the same `req.writer.interface`
  every buffered response already writes through.
- `begin_stream`/`write_chunk`/`end_stream` added to the `VTable` in
  `lua_vtable.zig` and wired into `makeVTable`.
- Matching delegate methods added to the `Context` struct in
  `zig/meteorite.zig`.
- Three new plain Lua globals registered in `zig/bridge/lua_bindings.zig`:
  `stream_begin(status, content_type)`, `stream_write(chunk)`,
  `stream_end()`.
- **This compiles cleanly** against the real Meteorite codebase — verified
  via `moon exec -- zig build` for the `basic-service` fixture app, in both
  its original `release-static` mode (streaming code present but unused —
  confirms it doesn't break the default path) and after adding a test
  route requiring hybrid mode.
- **Zero regression**: the existing `fixtures/tests/basic-service-http.sh`
  suite passes unchanged after all of the above.

### Update (2026-09-07): live socket proof achieved, root cause fixed

The hybrid-mode banner discrepancy below was root-caused and fixed in
Meteorite's own repo (not Hydronium's). Two independent bugs, both in
`fixtures/apps/basic-service`, combined to produce the symptom:

1. **`fixtures/apps/basic-service/build.zig` and `zig/main.zig` were a
   stale, hand-written duplicate** of Meteorite's real build path. Every
   other Meteorite app (real, `meteorite init`-generated, or the
   framework's own repo-root `build.zig`) builds by calling
   `meteorite.addService(b, .{...})` from `zig/build_api.zig` — a single,
   actively-maintained function that always compiles the framework's own
   `zig/main.zig` (correct, mode-aware `LuaRuntime`/`SelectedBackend`
   selection) as the executable's root module. `basic-service`'s build.zig
   predated this and reimplemented the wiring by hand, incompletely — it
   never passed `.lua_runtime` to `meteorite.compile(...)` in its own
   local `zig/main.zig`, so `@hasField(@TypeOf(spec), "lua_runtime")` was
   always `false` regardless of `-Dmode`. Fixed by replacing
   `basic-service`'s `build.zig` with a thin wrapper around
   `meteorite.addService` (matching the CLI-generated project template
   and the framework's own repo-root `build.zig`) and deleting the
   now-dead local `zig/main.zig`.
2. **`zig/build_api.zig`'s default `lua_root` option was wrong**:
   `.moonstone/env/libexec/lua/files` (one path segment too many — the
   moonstone-materialized `lua` libexec entry *is* the `files/` directory,
   not a parent of it), so `include/lua.h` and `lib/liblua.a` were never
   found by default. Fixed the default to `.moonstone/env/libexec/lua` in
   both `zig/build_api.zig` and the `meteorite init` template
   (`src/cli/templates.lua`).

With both fixed, `moon exec -- zig build -Dmode=release-hybrid
-Dbackend=std_http` inside `basic-service` now correctly prints `mode:
hybrid` / `Lua runtime: included`. A `/stream-test` route
(`stream_begin(200, "text/plain")` → `stream_write("prefix")` → 1s delay
→ `stream_write("suffix")` → `stream_end()`) was added, built, and probed
with a raw Python socket (`socket.create_connection` + timestamped
`recv()`), against the real running binary — no mocks:

```
[ 0.005s] recv 129 bytes: b'HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n...'
[ 0.005s] recv  11 bytes: b'6\r\nprefix\r\n'
[ 1.013s] recv  16 bytes: b'6\r\nsuffix\r\n0\r\n\r\n'
```

Headers plus the first chunk arrive immediately; the second chunk arrives
~1.008s later, matching the handler's `os.execute("sleep 1")` between the
two `stream_write` calls — real incremental HTTP/1.1 chunked delivery over
a live socket, not a synthetic benchmark. (One unrelated, minor
observation: the server sent a stray `HTTP/1.1 204 No Content` after the
stream ended despite the client's `Connection: close`, a `std_http`
backend connection-loop edge case, not a streaming-code defect — not
chased further, out of scope for this fix.)

The `/stream-test` route was reverted from the shared `basic-service`
fixture afterward (an inline-Lua route breaks that fixture's
`release-static` regression tests), matching the original scoping
decision below. All of `basic-service-build.sh`, `-http.sh`, and
`-contracts.sh` pass unchanged in `release-static` mode after all of the
above.

### Update (2026-09-07): the streaming primitive used for a real HMR dev-transport trigger

Closes one item from `docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md`'s "Left
open" list: **file change on disk → real push notification to a connected
client** — not the browser-side listener or `RefreshRegistry` wiring,
which stay separate, larger, and still open.

**Constraint that shaped the design, found by reading the code, not
assumed:** `examples/meteorite_ssr` is built with the `std_http` backend,
which is strictly single-connection-serial —
`zig/backends/std_http.zig` sets `threaded_connections = false` and
`pooled_connections = false`, and `zig/meteorite.zig`'s accept loop calls
`serveConnection` inline; a handler that never returns doesn't just block
other requests, it freezes the whole server's `accept()` loop. An
indefinite SSE stream (the shape used for `/stream` above) is therefore
not viable for a watch endpoint on this backend. The route below uses a
**bounded long-poll** instead: a client-supplied budget (default 5s), a
0.5s poll interval, and a `since=<fingerprint>` handoff so a change that
happens while nothing is connected is still caught on the very next
connection rather than lost in the gap between polls.

Detection is a `stat`-snapshot poll — the same technique Ballad's own file
watcher already uses in this stack
(`.moonstone/env/libexec/ballad/src/ballad/plugins/watcher.lua`), so no
new dependency (no `luafilesystem`) was needed. `%Fm` (BSD `stat`, this
machine) / `%.9Y` (GNU `stat`) give sub-second mtime precision; plain
`%m`/`%Y` are whole-seconds and can miss an edit landing in the same
second as a poll.

The new route: `GET /__hydronium/watch` in `examples/meteorite_ssr/src/main.lua`,
self-contained per this file's own handler-lifting constraint (see its
header comment). Watches exactly `views/App.luax` and
`src/views/App.lua` — not a directory walk, which would traverse
`.moonstone/env/`'s thousands of files every poll.

**A real bug found and fixed during verification, not anticipated in the
plan:** the fingerprint was originally newline-joined
(`table.concat(lines, "\n")`). Round-tripping it through a `since=`
query parameter (percent-encoded as `%0A`) got a real
`HTTP/1.1 400 Bad Request` from Meteorite's router — a legitimate
CRLF-injection guard, not a bug in Meteorite. A literal embedded newline
in an SSE `data:` line is also malformed per the SSE spec (a multi-line
payload needs one `data:` prefix per line, which the implementation
wasn't doing either). Fixed by joining with `"|"` instead, which needs no
encoding at all since it never appears in a `stat` line's own content.

**Live, timestamped proof, three runs against the real rebuilt binary**
(`moon exec --dev meteorite graph ...` then
`zig build -Dmode=release-hybrid -Dbackend=std_http`), via the same raw
Python socket technique used for the original streaming proof above —
`curl -N` would show the events but flattens the timing evidence that's
the actual point:

**Run A — heartbeat and clean budget expiry, no edit** (`?budget=3`):
```
[  0.010s] event: hello  data: ...App.lua|1788807790.245608427 6003 views/App.luax
[  2.109s] event: ping   data: 2.0
[  3.161s] event: bye    data: ...App.lua|1788807790.245608427 6003 views/App.luax
[  3.161s] connection closed by server
```

**Run B — the actual claim: live edit mid-stream** (`?budget=10`; file
touched at wall-clock `1788807860.525106`, ~2s after connecting):
```
[  0.009s] event: hello  data: ...App.lua|1788807790.245608427 6003 views/App.luax
[  2.069s] event: reload data: ...App.lua|1788807860.526486241 6048 views/App.luax
[  2.069s] connection closed by server
```
The `reload` frame's own embedded mtime (`.526486241`) lands ~1.4ms after
the actual write (`.525106`) and arrives on the very next 0.5s poll tick
— the evidence is that timestamp delta, not just the frame's presence.

**Run C — the reconnect race** (the case a naive long-poll gets wrong):
baseline fingerprint fetched, file edited with **nothing connected**
(wall-clock `1788807886.682253`), then reconnected with
`since=<the stale baseline>`:
```
[  0.008s] event: reload data: ...App.lua|1788807886.682844714 6048 views/App.luax
[  0.008s] connection closed by server
```
Immediate `reload` on the very first frame (no poll wait at all) — the
embedded mtime (`.682844714`) matches the edit (`.682253`) to within
~0.6ms, proving a change during a gap with no connection at all is still
caught, not just changes that happen to land while a client is already
watching.

Regression check: all pre-existing routes (`/`, `/api/health`, `/mixed`,
`/islands`) return `200` against the rebuilt binary; hydronium's own
356-spec LuaJIT suite is unaffected (this touches only the example app,
not the framework).

**Explicitly not proven by this work**: no browser `EventSource`
consumer exists; no `RefreshRegistry` wiring; client-disconnect-mid-stream
remains as untested as it was for the original streaming primitive (see
"What remains genuinely open" above) — the bounded budget sidesteps
needing that path to be correct rather than proving it is.

### Update (2026-09-07): switched the example to `fast_http`, the serial-backend hazard is gone

The example is meant to reflect what shipping to production actually
looks like, and `fast_http` — not `std_http` — is meteorite's own
production default (`zig/build_api.zig`'s `fast_http_strategy` defaults
to `"threaded_probe"`, no extra build flag needed). Switched both
`examples/meteorite_ssr/build.zig`'s default `-Dbackend` and
`moonstone.toml`'s `graph` script from `std_http` to `fast_http`,
regenerated the graph, and rebuilt
(`zig build -Dmode=release-hybrid -Dbackend=fast_http`) — this
constant had never been exercised on this backend before, so the whole
existing route suite needed re-verification, not just the new one:

- Startup banner: `backend: fast_http`, `Lua runtime: included` — build
  is sound.
- All pre-existing non-streaming routes (`/`, `/packages/:name?v=...`,
  `/error-test` — 500, its own deliberate demo — `/api/health`,
  `/islands`, `/mixed`, both `meteorite.site` static asset routes)
  return the same codes as on `std_http`.
- `/stream`'s real incremental chunked delivery is unchanged: the same
  5 feed rows arrive ~0.4s apart, matching each row's own
  `os.execute("sleep 0.4")`, verified via the same raw-socket technique.
- All three `/__hydronium/watch` probes (heartbeat/budget, live edit
  mid-stream, reconnect-race) re-run against the `fast_http` binary
  with materially identical timing to the `std_http` results above
  (e.g. `reload`'s embedded mtime landing ~1.9ms after the actual write
  in the live-edit run).

**The actual point of switching, proven directly, not inferred from
`threaded_connections = true`:** started a `/__hydronium/watch?budget=8`
connection, then — *while it was still open*, mid-poll-loop — issued
`GET /` and `GET /api/health` concurrently. Both returned `200`
immediately (`0.015s` and `0.001s` respectively via `curl`'s own timing),
while the watch connection kept running its full 8-second budget
(pings at 2/4/6/8s) independently in the background. On `std_http` this
would have hung both requests until the watch connection closed — this
is the serial-backend hazard from the update above, and it's now gone:
`fast_http`'s `connectionStarted`/thread-per-connection model
(`zig/backends/fast_http.zig`) really does let an open long-poll and
ordinary page loads coexist, not just in theory.

Full 356-spec LuaJIT suite unaffected (example-app-only change, same as
the original route addition).

### Historical record: what this session originally found (superseded above)

A `/stream-test` route (`stream_begin` → `stream_write("prefix")` → 1s
delay → `stream_write("suffix")` → `stream_end`) was added to a copy of the
`basic-service` fixture and the app was rebuilt in hybrid mode
(`zig build -Dmode=release-hybrid`). The build succeeded, but the resulting
binary's own startup banner reported `Lua runtime: removed` regardless of
the mode flag, and the route correctly-but-unhelpfully returned
`501 handler requires Lua runtime`.

Tracing this (`zig/main.zig`): `final_requires_lua = requires_lua or
build_info.lua_runtime`, where `build_info.lua_runtime` is generated by
`build.zig` as `!std.mem.eql(u8, mode, "release-static")` — which, by
inspection, should correctly evaluate `true` for `mode=release-hybrid`.
`LuaRuntime` is then selected as `bridge.HybridLuaRuntime` (not
`LuaRuntimeUnavailable`) when `final_requires_lua` is true. The wiring
*reads* as correct. **This turned out to be true of the shared
`zig/main.zig` — the bug was that `basic-service` wasn't actually
compiling that file at all (see the fix above).**

The streaming-specific test route was reverted from the shared
`basic-service` fixture (to avoid leaving a shared test fixture in a
broken, half-modified state); the underlying Zig library changes
(`context_response.zig`, `lua_vtable.zig`, `lua_bindings.zig`, and the three
backends) were kept, since they are purely additive, compile cleanly, and
introduce no regression to the default (`release-static`, no
Lua/streaming) build.

## What remains genuinely open (not just "more implementation")

- **Header commitment enforcement** is implemented as a simple flag check
  (`ctx.response_committed`), matching the existing buffered-response
  pattern — not independently stress-tested against concurrent mutation
  attempts.
- **Client disconnect mid-stream**: not implemented or tested. A write to a
  closed socket would surface as a Zig error from `writeAll`/`flush` (the
  same as it would for a buffered response today) — whether that correctly
  unwinds and disposes a Hydronium render scope was not exercised, since
  the live proof itself was blocked.
- **Errors after `beginStream`**: by construction, once headers are sent
  there is no way to change the status code — this was a design decision
  made in `beginStream`'s doc comment, not verified against an actual
  mid-stream error scenario.
- **This was implemented and reasoned about for the `std_http`/`fast_http`/
  `unix_socket_http` connection-level backends specifically; IPC/non-HTTP
  transports were not considered.**

## Environment issue discovered (surfaced for the owner, not invented)

`moon exec -- zig build` (the working invocation for this session) and the
repo's own `fixtures/tests/basic-service-build.sh` (which calls
`partiture.lua` via ballad) are two different build orchestration paths.
The latter failed on a clean re-run in this environment with
`cp: .meteorite/graph/current: No such file or directory` — a
pre-existing issue independent of anything touched this session (verified
by the fact that `basic-service-http.sh`, run against a binary built via
the working `zig build` path, passes cleanly). Whether these two build
paths are expected to diverge, or whether one is stale, was not resolved.

## Answers to the mission's specific unresolved questions

1. **Does Meteorite want response streaming as a core framework primitive?**
   Not answerable from code — this is a genuine product decision for
   Meteorite's owner. The architecture doesn't preclude it (see above), but
   the framework's own `release-compiler-contract` explicitly scopes out
   "connection-upgrade lifecycle, backpressure, and long-lived stream
   contracts" today (`src/core/app.lua:198-207`), suggesting it may be
   deliberately out of scope rather than merely unbuilt.
2. **Is the `stream_begin`/`stream_write`/`stream_end` API shape (plain
   globals, positional args) the right public surface, or should it match
   `ctx:text(...)`'s richer table/options convention?** This session's
   implementation deliberately kept it minimal to isolate the underlying
   primitive from API design; the real answer needs Meteorite's own
   context-API conventions applied by someone fluent in that codebase's
   established patterns.
3. **Root cause of the hybrid-mode banner discrepancy** — resolved
   2026-09-07, in Meteorite's own repo: `fixtures/apps/basic-service` had
   a stale, hand-written `build.zig`/`zig/main.zig` that bypassed the
   framework's real build path (`meteorite.addService`), plus a wrong
   default `lua_root` path in `zig/build_api.zig`. See the update at the
   top of this document.

## Bottom line for the sequencing decision

The counter-hypothesis is **substantially correct for Meteorite's half**:
the missing primitive is a small, well-bounded addition to an
already-clean abstraction, not a rearchitecture — proven by writing it and
watching it compile cleanly against the real codebase with zero
regression, and now confirmed end-to-end: the hybrid-mode build issue was
an orthogonal, pre-existing build-wiring bug (fixed 2026-09-07, see the
update above), not architectural open-endedness, and the live socket
proof it was blocking has since been obtained. This is a materially
different, more favorable finding than the previous session's "Meteorite
has zero streaming support, foundational changes needed" — that earlier
statement was true about *today's shipped code*, but overstated the *cost
of closing the gap*.
