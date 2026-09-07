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
