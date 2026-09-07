# Hydronium/Meteorite Next Sequence Decision (Evidence-Based)

This document exists to answer one question honestly, after actually
attempting the work rather than estimating it: **is "example first" the
lowest-risk sequence, or can the missing foundational primitives be built
now, using a real example continuously as the integration test?** Audit
date: 2026-09-07.

## Unknowns, classified with evidence (not intuition)

| Unknown | Classification | Evidence |
|---|---|---|
| Meteorite: minimal streaming write primitive | **SMALL CONTRACT** | Implemented this session. Compiles cleanly against the real codebase across all 3 backends + the generic VTable/Response abstraction. Zero regression on existing tests. See `METEORITE_STREAMING_FOUNDATION.md`. |
| Meteorite: backpressure for streaming | **ALREADY SOLVED, not a new primitive** | Comes free from existing blocking-socket-per-connection I/O; the same `flush()` every buffered response already calls. |
| Meteorite: header-commit-once semantics | **SMALL CONTRACT** | A boolean flag check, same pattern as existing `response_committed`/`response_staged` flags. |
| Meteorite: client disconnect mid-stream | **IMPLEMENTATION WORK, unverified** | Mechanism (Zig write error) exists in principle; not exercised, since the live proof was blocked by an unrelated build issue. |
| Meteorite: hybrid/Lua-mode initialization in this dev environment | **ACTUALLY OPEN (as a bug), but narrow** | A real, reproducible discrepancy between `main.zig`'s (apparently correct) `lua_runtime` selection logic and the compiled binary's runtime behavior. Root cause not found this session. Narrow in scope — affects a single build-wiring question, not the language/architecture. |
| Hydronium: sink-based server rendering | **ALREADY DONE** | `server.render(vnode, sink)` exists today, independent of Meteorite, per the prior session's audit. |
| Hydronium: client manifest format | **SMALL CONTRACT (design), IMPLEMENTATION WORK (code)** | No existing code; the shape (list of islands with id/interpreter/module/props) is a straightforward, well-precedented data structure. Not attempted this session — pure design work, low risk to defer. |
| Hydronium: WASM Lua runtime choice | **RESEARCH DECISION — resolved to a real candidate** | `wasmoon` (real, actively-versioned npm package wrapping Lua 5.4 in WASM, minimal dependencies) confirmed reachable and installable this session. A reasonable default hypothesis, not yet integrated. |
| Hydronium: DOM-claiming / hydration algorithm | **ACTUALLY OPEN-ENDED** | No existing design beyond `SSR_HYDRATION_CONTRACT.md`'s prose (itself corrected this repo-audit-pass to explicitly say "design spec, not implementation"). Requires: a bundler/build step, a real browser to test in, and original algorithm design (stable ID matching, event delegation strategy) that has no existing precedent in this codebase to extend. |
| Hydronium: actually testing hydration | **BLOCKED IN THIS ENVIRONMENT** | No browser-automation tool was available this session (checked; none connected). This is not a code-complexity finding, it's a tooling-availability finding — but it's real and matters for *this* environment's near-term sequencing regardless of the code's inherent difficulty. |
| Hydronium: JS-only / mixed Lua+JS islands | **DESIGN NOT STARTED** | Not investigated this session; no evidence gathered either way. |

## Architecture surface, not calendar time

For the one slice actually attempted (Meteorite streaming):
- **New contracts**: 1 (the `beginStream`/`writeChunk`/`endStream` triad).
- **Modified ownership boundaries**: 1 (`context_response.zig`'s generic
  `Response(...)`, already the correct seam — no new boundary invented).
- **Backends touched**: 3 of 3 (required for the generic code to compile at
  all — Zig's function-pointer vtable forces every backend to implement the
  interface, even backends that never call it in a given app).
- **New Lua-facing API surface**: 3 global functions.
- **Serialization formats added**: 1 (HTTP/1.1 chunked transfer-encoding —
  a standard, not a new invention).
- **Lifecycle states added**: 1 (`response_committed` gains a second way to
  become true, no new state machine).
- **Regression tests broken**: 0.
- **New tests added and passing**: 0 live (blocked by the environment
  issue) — the Zig code compiles and was manually verified for correctness
  by construction (RFC 7230 chunk framing), not by an automated test.

This is a small surface. It does not resemble "several weeks of
foundational work" — it resembles a focused, single-session Zig change
that happened to hit an unrelated environment snag on the way to a live
demo.

For hydration, no equivalent table can honestly be produced yet, because
no implementation was attempted — and the reason none was attempted is
itself the finding: it requires a browser-testing capability this session
didn't have, a runtime dependency choice that, while resolved in principle
(wasmoon), still needs to be integrated and exercised, and original
protocol/algorithm design with no existing scaffold to extend. That is a
qualitatively different kind of unknown than Meteorite streaming turned out
to be.

## Sequence scoring

| Criterion | Seq 1: Example-first | Seq 2: Foundation-first | Seq 3: Continuous vertical slice |
|---|---|---|---|
| Architecture feedback speed | Slow (defers the hard parts) | Fast for the part attempted (proven this session for streaming) | Fast, and evidence-based per slice |
| DX feedback speed | Fast initially, but on a soon-to-change API | Slow (nothing user-facing until foundations land) | Fast, continuously |
| Risk of API ossification | High avoided short-term, paid later | Low for streaming (bounded); unknown for hydration (could ossify around an untested design) | Lowest — each primitive is used by the same real app immediately |
| Untested boundaries | Many, deferred | Few for streaming; hydration would still be speculative without a browser | Fewest — a real app exercises each boundary as it's added |
| Ability to revert | Easy (nothing built yet) | Harder for hydration if built speculatively without real usage | Easy — small increments, each independently useful |
| Cross-project coupling | None added yet | Meteorite gets a real new capability regardless of Hydronium (streaming benefits Meteorite standalone) | Same benefit, same independence |
| Performance observability | None until the end | Real for streaming (once live-tested); none for hydration until browser-tested | Real, per-slice, as each lands |
| Implementation independence | N/A | Streaming: proven independent and additive. Hydration: not yet proven | Same, tracked per-slice |

**Sequence 3 wins on the evidence**, but with an important asterisk the
mission's own framing didn't anticipate: *the two "foundational" pieces are
not equally ready.* Meteorite streaming earned its way into "build it now"
by actually being built and found small. Hydration did not — not because
it's proven to be many weeks of work either, but because this session
could not produce equivalent evidence for it (no browser tooling, no
existing algorithm to extend, a real but not-yet-integrated runtime
dependency).

## Recommendation

Adopt Sequence 3, but sequenced honestly by *demonstrated* readiness, not
by the order originally proposed:

1. **Real example app on today's buffered SSR** — already true today (this
   session verified all routes over live HTTP, including a fixed SVG icon
   exercising the earlier session's fixes).
2. **Meteorite streaming, finished** — resolve the hybrid-mode
   initialization discrepancy found this session (a narrow, well-described
   bug, not a redesign), then re-run the exact `/stream-test` route this
   session prepared (reverted, but fully specified in
   `METEORITE_STREAMING_FOUNDATION.md`) to get the live-socket proof this
   session couldn't complete.
3. **Hydronium sink adapter wired to real Meteorite streaming** — thin
   glue once step 2 lands; `hydronium.server`'s sink contract already
   supports it.
4. **THEN, separately and explicitly scoped smaller than "hydrate a
   Counter": load wasmoon in an actual browser and run one Lua expression.**
   This is the honest "smallest next hydration slice" — not a claim, a
   downgrade from the mission's own Part V proof target, because that
   target presumes DOM-claiming and event-attachment design work this
   session found no existing scaffold for. Prove the runtime loads and
   executes Lua in a real browser *before* designing the hydration
   protocol around it.
5. **Client manifest design** — can happen in parallel with step 4 as a
   pure design task (no implementation blocker), since it's a data format,
   not code that needs a browser to validate.
6. **Full Counter hydration proof** — only after 4 and 5 both land.
7. **Expand the same example app continuously**, exactly as the mission's
   Part VIII argues — this part of the counter-hypothesis is fully
   correct and adopted without qualification.

## Update (2026-09-07): steps 1-3 done, with real evidence

Recommendation steps 1-3 above are complete, verified against a real
compiled Meteorite binary (not `meteorite invoke`, not mocks) — see
`METEORITE_HYDRONIUM_INTEGRATION_BRIEF.md` §7 for the full account:

1. Meteorite's hybrid-mode Lua runtime build bug (§ blocking item above)
   was root-caused and fixed in Meteorite's own repo.
2. `examples/meteorite_ssr` is now a real compiled Meteorite service
   (`moonstone.toml` + `build.zig`, mirroring `fixtures/apps/basic-service`)
   with both buffered and streaming SSR routes, exercised live over a raw
   socket.
3. `hydronium.server`'s sink contract needed zero changes to drive real
   incremental per-node HTTP delivery — confirmed, not just architecturally
   plausible: a live `/stream` route shows the page shell arriving in one
   burst of chunks and a 5-row list arriving one chunk per row at the
   expected cadence.

Two more real bugs were found only by actually compiling and running this
(not by code review): Meteorite's hybrid inline-handler "source lifting"
rejects the adapter's factory-closure pattern (`.handler`/`.stream_handler`
need a literal, self-contained handler body instead), and the adapter's
buffered-response fallback put `content-type` in the reserved `headers`
table. Both fixed.

**Still not attempted**: step 4 (wasmoon in a real browser) and beyond —
client hydration remains untouched by this update. The "slow" rows in
`/stream` are a hand-placed `os.execute("sleep 0.4")`, not a real
async/Suspense boundary; Hydronium has no such primitive yet.

## What this does NOT mean

This is not "hydration is several weeks of work" restated. It means: one
half of the originally-feared foundational work (Meteorite streaming) was
tested and found small; the other half (browser hydration) was not tested
this session because the tooling to test it wasn't available, and honesty
requires not claiming a result that wasn't produced. The next session
should attempt step 4 above specifically *to get the same kind of evidence
for hydration that this session got for streaming* — a small, falsifiable
proof, not an estimate.

## Update (2026-09-07, later): Island/Suspense/Resource contracts landed (a separate mission's steps 1-3)

A separate, much larger architecture brief ("Unify `d.<interpreter>.island`,
Streaming Suspense, Progressive Hydration") arrived and was scoped down the
same way this document scopes things down: audit first (found zero
existing island/suspense/resource code anywhere in `src/`), then implement
only that brief's own Part XXII steps 1-3 for real. See
`HYDRONIUM_ISLANDS_SUSPENSE_V1.md` for the full ground-truth account. Step
4 of *that* sequence (wasmoon in a real browser) is the same step 4 this
document already recommended — both documents now point at the same next
action.

## Update (2026-09-07, later still): step 4 attempted

`wasmoon` (real Lua 5.4 in WebAssembly) was installed and used to
`require()` Hydronium's real, unmodified `hydronium.core.element` and
call its real `createElement()`, verified directly in Node with actual
console output inspected — real VNode returned, real closures/upvalues
survived, real `_VERSION`/error-format checks confirming it's genuine
Lua 5.4, not a JS shim. A matching browser page (a Claude Artifact, with
the WASM binary embedded as a `data:` URI to route around the artifact
sandbox's CDN-runtime-fetch restriction) was built and published, but not
independently confirmed working in an actual browser — this session has
no browser-automation tool. See `HYDRONIUM_ISLANDS_SUSPENSE_V1.md` for
the full account. The core technical risk (does Hydronium's real code run
in Lua-in-WASM at all) is now settled with hard evidence; whether it also
runs in an actual Chrome tab is the one thing still waiting on the user.

**Pushed further, same session**: a real, narrow `hydronium.interpreter.lua`
now exists and was verified two more independent ways (real WASM Lua with
an async JS→Lua click callback driving a real signal/effect; a real DOM
via jsdom exercising the actual TreeWalker/comment-marker/click-dispatch
logic against the real SSR HTML shape) plus a 7-test LuaJIT spec in the
regular suite (343/343 passing). Full account, including a real
test-isolation bug this caught and fixed, in
`HYDRONIUM_ISLANDS_SUSPENSE_V1.md`.
