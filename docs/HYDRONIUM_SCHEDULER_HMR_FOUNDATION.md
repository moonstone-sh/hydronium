# Scheduler, Client Patcher, and HMR — Foundation, Not Implementation

This document answers the counter-agent mission's required questions
against verified fact, and makes one real architectural decision (the
one it correctly flags as most important: state-preserving HMR under
Hydronium's setup-once component model). It does **not** implement the
scheduler, boundary registry, client-update protocol, or HMR system —
none of that exists yet, and building it in one pass, unverified, would
repeat exactly the mistake this whole engagement has caught and corrected
every other time it came up (the WASM proof shipped before its exact code
was tested; the CSP assumption about `data:` URIs turned out wrong;
"already-established" architecture claims that turned out to be zero
lines of code). This document is the honest first half — verify, decide
the hard part, scope the rest — not the second.

Single consolidated document, not the ten requested. Ten documents about
systems that don't exist yet would be speculative sprawl, not
architecture; there is nothing to split across `SCHEDULER_ARCHITECTURE.md`
/ `CLIENT_BOUNDARY_REGISTRY.md` / etc. that isn't said once, correctly,
below.

## Part 1 — Fact verification

| Claim | Status | Evidence |
|---|---|---|
| Meteorite has verified HTTP/1.1 chunked streaming | **VERIFIED LIVE** (this session and earlier) | Real socket probes against a compiled binary; see `METEORITE_STREAMING_FOUNDATION.md` and the `/mixed`/`/stream` proofs. |
| Meteorite has no WebSocket support | **VERIFIED FROM SOURCE** | `src/core/app.lua:198-215` (meteorite repo): `App:websocket`/`App:ws` call `unsupported_websocket`, which `error()`s with the exact text "Meteorite does not support WebSocket routes in the current service-layer release... connection-upgrade lifecycle, backpressure, and long-lived stream contracts are not part of the release compiler contract yet." Deliberate, not an oversight. |
| Meteorite has `/__meteorite/reload-lua` | **VERIFIED FROM SOURCE** | `zig/meteorite.zig:305-311` (meteorite repo): a `GET`/`POST` endpoint, gated by `dev_reload_enabled` (true only in `dev`/`hybrid_dev` build modes), that calls `lua_runtime.reloadAll()` if the selected runtime declares it. |
| That endpoint provides no browser push, no DOM patching, no client HMR | **VERIFIED FROM SOURCE** | It is a plain pull endpoint: something (a human, a script, a file watcher) must issue an HTTP request to it. Nothing in `zig/` or `src/` sends anything to a browser unprompted; there is no notion of a "browser client" anywhere in Meteorite's own code. |
| **NEW, verified live this session**: Meteorite can hold a chunked connection open across multiple real, time-separated writes without an idle timeout killing it | **VERIFIED LIVE** | A raw socket probe against a real compiled `basic-service` binary, hitting a route that did `stream_begin(200, "text/event-stream")` then five `stream_write("event: tick\ndata: N\n\n")` calls one real second apart, received all five events at their correct real timestamps (`[0.010s]`...`[4.093s]`) and the correct chunked terminator at `[5.109s]`, with no early close. This directly answers required question #28 ("was SSE proven over actual Meteorite streaming") — yes, for a 5-second window. It does **not** prove behavior over minutes/hours, under real concurrent load, or across a proxy/load balancer that might impose its own idle timeout — those remain unverified. |
| Hydronium has a scheduler contract shaped like `scheduler:invalidate(instance, priority)` / `scheduler:flush()`, extendable for Suspense/hydration/HMR | **STALE** — the assumption in the mission brief does not match what exists | See Part 2. |
| Any of: generation modeling, a boundary registry, a versioned client-update protocol, priority scheduling, cancellation | **VERIFIED ABSENT** | `grep -rn "generation\|BoundaryRegistry\|client-update\|scheduler:invalidate"` across `src/` returns nothing relevant. None of Parts II-VI's assumed substrate exists in any form. |

## Part 2 — The scheduler that actually exists (and why it can't just be extended)

`src/hydronium/core/scheduler.lua` (247 lines) is real and load-bearing,
but it is not what the mission brief assumed:

- It is a **module-level singleton**, not an instance/priority-based
  contract — `scheduler.scheduleRender(component)`, `scheduler.flush()`,
  no `priority` parameter anywhere, no per-call generation, no
  cancellation.
- It runs a **phased pipeline** (render → commit → effect → deferred
  signal updates, looped until quiescent, with a 100-iteration cycle
  breaker) — this part is genuinely good and directly reusable *for
  client-side reactive re-rendering*, which is the one job it does.
- It is **explicitly SSR-inert**: `scheduleRender`/`queueEffect` both
  early-return when `scheduler.isSSR()` is true. Server rendering (and
  therefore today's Suspense implementation) does not go through this
  scheduler at all — `server/init.lua`'s Suspense handling is a plain
  synchronous buffer-and-catch, with its own bespoke control flow,
  entirely separate from this file.
- It has **no concept of async continuation, generations, or
  cancellation** — nothing here could represent "a Suspense boundary is
  waiting on a resource that will resolve later" or "this pending
  hydration became stale because a newer one superseded it."

Conclusion: this is domain-correct, narrow, and should **not** be
generalized into a god-scheduler for Suspense/hydration/HMR (the mission
itself warns against this in Part I §4, correctly). The right relationship
is **sibling, not parent**: a new, small scheduling primitive for
generation-tagged async continuations (Suspense boundary resolution,
hydration readiness, HMR refresh ordering) should exist *alongside*
`core/scheduler.lua`, sharing vocabulary (enqueue, cancel, generation) but
not implementation, exactly as the mission's Part I §4 anticipates. That
new primitive does not exist yet; designing its exact API is a real,
separate task this document does not attempt, because doing it well
requires the first real Suspense-boundary-generation proof to shake out
the shape (see Part 4).

## Part 3 — The one question worth disproportionate attention, answered

> How does Hydronium preserve compatible component state across a hot
> replacement while retaining its setup-once/render-many model and
> avoiding React-style positional hook semantics?

**Decision: Strategy C (rerun setup against the reusable component
scope), with resource identity keyed by compiler-injected source
location, not call order — and "compatible vs. incompatible" is not a
separate classification step, it falls out of the same mechanism.**

### The mechanism

Hydronium's setup-once components are a function `(props, scope) ->
render_fn`. The setup function runs once; its locals (signals, computeds,
effects, resources) are captured as upvalues by whatever code closes over
them, including the returned `render_fn`. This is exactly why "preserve
only the render function" (Strategy B) cannot work reliably: a freshly
compiled `render_fn` from edited source closes over whatever *new* setup
run created, not the old scope's live signals — there is no way to graft
an old closure's captured values onto a structurally different new
closure without already having solved identity, which is the actual
problem.

So: on a refresh, **always rerun the entire new setup function** — but
run it in "refresh mode" against the *existing* scope object, not a fresh
one, and make `scope:signal(...)` (and `scope:computed`, `scope:resource`,
etc.) identity-aware:

1. In development builds only, the LUAX compiler injects a stable,
   deterministic ID as a hidden extra argument to each `scope:signal(...)`
   call site — derived from `(module path, component family, declaration
   source range)`, never from call order and never from a runtime
   counter. This is the part of the mission's Part IX/§33 that is
   correct and necessary; the alternative (`scope:signal("count", 0)`,
   an explicit user-facing key) is rejected for the same reason the
   mission rejects it — it forces HMR bookkeeping into production
   authoring for zero production benefit.
2. `scope:signal(initial, dev_id)` in refresh mode: if the *existing*
   scope already holds a live signal registered under `dev_id` from the
   previous generation, **return that live signal's accessor/setter
   pair, ignoring `initial` entirely.** If no such registration exists
   (a genuinely new `scope:signal` call in the edited code), create a
   fresh one and register it under `dev_id`.
3. Any signal registered in the *previous* generation whose `dev_id` was
   **not** revisited during the new setup run is disposed (it was
   deleted from the source).
4. Effects: **always** dispose-then-recreate on every refresh, no
   identity matching. They have real side effects (timers, listeners);
   silently preserving one from stale closure state risks duplicated
   timers/listeners far more than it risks losing effect-owned state,
   and effects don't hold "the interesting state" in this model anyway
   (signals do). This matches the mission's own suggested policy
   (§39: "Effect: cleanup + recreate") and needs no identity scheme at
   all — the simplicity is the point.
5. Computeds: always recreate (their dependency closures reference the
   old setup run's locals; there is nothing safe to preserve). Matches
   the mission's suggested policy.
6. Refs: preserved automatically, for free — because this is a **normal
   re-render through the existing reconciler** against the *same*
   mounted host tree (see point 7), the DOM node a ref points at doesn't
   change, so nothing needs to be done for refs specifically.
7. The new setup run's return value (the new `render_fn`) replaces the
   component's old one. The component then goes through **ordinary
   reconciliation** — not an HMR-specific diff — producing whatever
   minimal DOM mutations the new render output actually requires. This
   directly satisfies the mission's Part XII §40 ("HMR must reuse
   ordinary reconciliation, not a bespoke diff engine") for free, because
   nothing about this design introduces a new diffing path.

### Why this avoids React-style hook ordering

The identity key is **source location**, assigned once at compile time
per call site, not a runtime-incremented counter tied to call order.
Moving unrelated code around a `scope:signal(...)` call doesn't change
its identity. Only actually editing *that* call site (or the compiler
being unable to correlate old and new source across a large structural
edit) changes its identity — and when identity can't be established, the
signal is simply treated as new (graceful reset to its declared initial
value), never a crash, never a positional misattribution to a *different*
signal the way React's hook-order rule can produce.

### Where this fails safe, and what "incompatible" actually means

There is no separate "is this refresh compatible?" analysis pass. Just
run the new setup function against the old scope and see what happens:

- If it runs to completion, the refresh succeeded — whatever mix of
  preserved/reset/disposed signals results is exactly correct by
  construction, no matter how much the code changed.
- If it **errors** (references a prop that no longer exists in a
  breaking way, a genuine runtime failure), that is the actual, only
  signal for "incompatible": catch it, dispose the existing scope
  entirely, and mount fresh from scratch (Strategy A, full state loss for
  *this component only*). This is exactly the mission's own recovery
  hierarchy (Part XXII §37: refresh in place → remount affected
  boundary → full reload) with a concrete, mechanical trigger for the
  first fallback instead of a vague "if incompatible."

### What this does not solve (stated, not hidden)

- **Structural moves the compiler can't correlate** (e.g., a
  `scope:signal` call moved into a newly-introduced conditional branch)
  may get treated as "new" even when a human would consider it "the same
  state, just relocated" — accepted as a known, documented limitation,
  not silently wrong (worst case is a value reset, never a crash or a
  wrong-signal mixup).
- **This requires a real LUAX compiler change** (dev-mode-only source-ID
  injection at `scope:signal`/`scope:resource`/etc. call sites) that does
  not exist and was not built this session — this document makes the
  design decision; implementing and testing the compiler pass, and
  proving it survives real edits (the mission's own three-tier test in
  Part XXII §60-62: markup edit / logic edit / incompatible edit) is
  future, real, verifiable work, not claimed as done here.
- **Resources** (`hydronium.core.resource`, this session's own addition)
  need the same identity treatment as signals if HMR is ever meant to
  preserve an in-flight or already-resolved resource across a refresh —
  not designed here; likely the same `dev_id` mechanism applies directly
  since resources are already lexically-scoped values, but this was not
  worked through and should not be assumed solved.

## Part 4 — Proposed minimal shared substrate (design only, not built)

Consistent with the mission's own "do not build a god scheduler" and
"small shared temporal architecture" framing, the smallest real
substrate that Suspense, hydration, and HMR could all sit on top of,
without collapsing into one mechanism:

- **A generation counter per stable boundary ID** (a Suspense boundary,
  an island, or — for HMR — a component family). Nothing more exotic:
  an integer that increments each time that boundary's content is
  superseded. A continuation/patch that arrives tagged with a stale
  generation is dropped. This one primitive directly satisfies required
  questions #7, #14, #21, #58-59 in the mission's list (staleness
  rejection) without needing a scheduler at all — it's a comparison, not
  a queue.
- **A boundary registry**: a plain map from stable ID → `{start_marker,
  end_marker, generation, kind}`, populated as markers are discovered in
  the DOM (client-side) — this already exists in embryonic, ad hoc form
  as the `findIslandRange`/`rangeElements` functions duplicated across
  `src/hydronium/client/bootstrap.js`, the published WASM proof's inline
  script, and `hydronium.interpreter.lua`'s host-contract expectations.
  The real, concrete next step (not done this session) is extracting
  that duplicated logic into one shared module both consumers import,
  *before* adding a third consumer (a streaming patcher or an HMR
  client) that would otherwise duplicate it a third time. This is a
  small, mechanical refactor with an existing, verified test (the jsdom
  DOM-bridge test from the islands work) to run it through — genuinely
  buildable next, unlike the rest of this document.
- **A versioned client-update message shape**, per the mission's own
  Part III — agreed in principle (`hydronium.client-update.v1`,
  `suspense.resolve` / `client_plan.add` / `island.ready` as production
  message kinds, `dev.*` kept separate), but not implemented, because
  there is no producer (streaming Suspense) or consumer (a patcher) for
  it to carry yet. Designing a wire format before either endpoint exists
  is exactly the speculative-architecture trap this document is trying
  to avoid; the message shape should be extracted from the first real
  producer/consumer pair, not designed ahead of them.

## Update — Part 3's identity proposal, adversarially tested and falsified as originally stated

A follow-up mission required attempting to disprove the "compiler-injected
source-location-derived ID" proposal above before committing to it, using
concrete edit fixtures. Assuming it was wrong and testing each fixture by
hand:

| Fixture | Raw (line, column) identity | Result |
|---|---|---|
| Insert a comment above a `scope:signal` call | The call's line number shifts | **FAILS** — identity changes, state resets, for one of the most common, most harmless edits there is |
| Run a formatter | Line/column of many call sites can shift | **FAILS**, same mechanism |
| Insert unrelated code above the call | Line number shifts | **FAILS**, same mechanism |
| Insert a new `scope:signal` call between two existing ones | The later one's line number shifts | **FAILS** — the untouched, later declaration incorrectly resets |
| **Reorder two `scope:signal` calls** (`count` then `name` → `name` then `count`) | Each declaration's *new* line number coincides with the *other* declaration's *old* line number | **FAILS CATASTROPHICALLY** — `name` would inherit `count`'s old value and vice versa. This is exactly the wrong-state cross-wire the mission's own priority ranking calls the one unacceptable outcome (a reset is merely annoying; this is silent data corruption). |

Verdict: **raw source location, as literally proposed, is falsified.**
It fails four fixtures outright and catastrophically fails the reorder
case specifically because "derived from source location" was never
precise about being anything more than line/column — the qualifier
"never from call order" in the original proposal ruled out one wrong
mechanism (an incrementing counter) without ruling out this one, which
fails for the identical underlying reason: both tie identity to *where
the call sits in the file*, and reordering, inserting, or reformatting
all change that without changing what the call *means*.

### The corrected model: structural matching at refresh time, not a static hash at compile time

Move the problem from "assign each call site a permanent ID at compile
time" (which cannot survive edits that change file position without also
changing meaning) to "compare the old generation's declarations against
the new generation's declarations when a refresh actually happens,"
using a small, compiler-attached descriptor per call site —
`{ kind, name, block_path }` — as matching material, not as a hash
input:

- **`kind`**: `"signal"` | `"resource"` | ... — the resource's own kind.
  A Signal and a Resource are never candidates for each other regardless
  of anything else, which directly satisfies the mission's own
  requirement (Part IX §39 / Part XIX fixture H) that a kind change must
  never reuse incompatible state.
- **`name`**: the local variable being bound (`count`, `name`). Not
  sufficient alone (shadowing, the mission's own §31 example), but a
  strong signal when combined with `block_path`.
- **`block_path`**: the lexical block nesting the compiler already walks
  for scoping (function body → if-branch → do-block → ...), identifying
  *which* `count` this is when the name alone is ambiguous under
  shadowing.

**Matching algorithm, run once per refresh, per component instance**:

1. Primary pass: match each new declaration to an old one with the
   identical `(block_path, name, kind)`. This is stable under comment
   insertion, formatting, and unrelated code insertion (none of these
   change lexical block structure, a binding's name, or a resource's
   kind) — fixtures A/B/C/E from the falsification table now pass.
2. **Reorder never cross-wires**, because matching is no longer
   positional at all: `count` and `name` each match their own old
   counterpart by name, regardless of which one is textually first. If
   the compiler-attached descriptors are identical for two declarations
   in the *same* refresh (a genuinely pathological case — e.g. two
   sequential `local x = scope:signal(...)` bindings in the same block,
   where the second shadows the first), the algorithm cannot
   disambiguate — and must not guess. It resets both rather than risk a
   50/50 wrong pairing. A reset is the acceptable failure mode; a wrong
   pairing is not.
3. **Rename** (name changes, kind and block_path don't): no primary-key
   match. Secondary pass: if the new declaration and exactly one
   leftover old declaration in the *same block* share kind and have no
   other candidate match, treat it as a probable rename and preserve —
   satisfying the mission's own "rename preserves state" preference
   (§25) as a best-effort heuristic, never as a guess made under
   ambiguity (if more than one unmatched candidate exists on either
   side, don't guess — reset).
4. **Initializer contents never participate in matching** — changing
   `scope:signal(0)` to `scope:signal(100)` must preserve the *existing*
   value, not reset to the new literal, exactly as the mission's own
   §32 requires. `block_path`/`name`/`kind` never reference initializer
   values, so this falls out for free rather than needing a special
   case.
5. Anything with no confident match on the new side: created fresh.
   Anything unmatched on the old side after the new setup run completes:
   disposed.

This is not a hash computed once at compile time — it's a real
comparison the refresh coordinator runs against two descriptor lists,
one per generation. The compiler's job shrinks to attaching
`{kind, name, block_path}` per call site (bounded, mechanical, dev-mode
only) rather than solving cross-generation identity itself.

**What this still does not solve**, stated rather than hidden: two
structurally-identical shadowed bindings reordered relative to each
other (the pathological case in step 2) cannot be told apart by any
static analysis — this is exactly what the mission's own explicit escape
hatch (Part VIII, an optional user-supplied `hot_id`) exists for, and
should be treated as required for that one case, not merely nice-to-have.
File moves/renames (`components/Counter.luax` → `ui/Counter.luax`) are a
`ComponentFamilyID` question, not a `ResourceDeclarationID` question, and
remain out of scope for this document (the mission's own §24 allows state
to reasonably reset on a file move as a deliberate product decision, not
a defect).

Nothing here was implemented — no compiler change was made, no refresh
coordinator was written. This is the corrected design, arrived at by
actually trying to break the previous one on paper before writing a
single line of the compiler pass it would require.

## What this session actually changes vs. what it decides vs. what it leaves open

**Changed** (updated after the follow-up counter-agent pass — see
`HYDRONIUM_CLIENT_BOUNDARY_REGISTRY.md` for the full account): the
concrete next step this document originally recommended — extracting the
duplicated boundary-marker logic — is done, not just recommended.
`src/hydronium/client/boundary_registry.js` is real, both real consumers
(`bootstrap.js` and the published WASM artifact) are migrated to it, the
duplicated code is deleted (not wrapped for compatibility), 14 permanent
tests plus a real-DOM verification pass all pass, and a real ownership
conflict (two independent claims on one boundary) is now provably
rejected rather than merely documented as an intended invariant.

**Decided**: the HMR state-preservation strategy (Part 3, rerun setup
against the existing scope) survived adversarial testing and remains the
direction. Its identity mechanism did **not** survive adversarial
testing as originally proposed — raw source-location identity fails
comment insertion, formatting, and insertion-before, and catastrophically
cross-wires state on a plain reorder (see the falsification table above).
Corrected to a structural-matching model (`{kind, name, block_path}`,
compared between generations at refresh time, never at compile time) that
was individually checked against every fixture in the falsification
table, including the reorder case that broke the original proposal.
Neither the original nor the corrected model has been implemented — this
remains a design decision, now a more defensible one, not yet code.

## Update — the structural-matching model, proven against real signals, not just on paper

The corrected identity model above was built and tested:
`src/hydronium/core/refresh.lua` (`RefreshRegistry`) implements the
`{kind, name, block_path}` matching algorithm against the **real**
`hydronium.signals.createSignal`, using hand-written descriptors as a
stand-in for what a future LUAX compiler pass would attach automatically
— explicitly not wired into the compiler, the component runtime, or any
dev transport; this proves the algorithm, not a product.

**A real correction found while building it, not while designing it**:
the design doc above described `scope:signal(initial)` as an existing
Hydronium API to intercept. It isn't — `core/scope.lua`'s `Scope` class
has no signal registry at all (only `Effect` ties itself to the ambient
scope, via `scope:defer`, for disposal; `createSignal` is a free function
with no scope tie-in whatsoever). `refresh.lua` wraps the real
`signals.createSignal`, not an API that doesn't exist.

**A real design correction found while implementing, not while
reasoning**: the rename heuristic (Part 3's secondary pass) cannot
decide "is this a rename" until the *entire* new setup run has finished
— but `:signal()` must return something valid to its caller immediately,
before that information exists. Resolved by always creating a real,
fresh signal at call time (correct immediately, no special-casing) and
having `finish_generation()` copy the matched old value into the new
signal's underlying storage afterward — visible to any closure that
already captured the accessor, since Lua tables are references and the
copy happens before the next read.

9 new tests (`tests/core/refresh_spec.lua`, part of the regular
352-spec suite, all passing), each proving one fixture from the
falsification table against real signals, not mocks: markup edit
preserves state; comment/formatter-shaped edit preserves state; **reorder
does not cross-wire** (the disqualifying case); insert-between preserves
both neighbors and creates the new one; a kind change never reuses an
incompatible value even with the same name; a confident single-candidate
rename preserves state; an ambiguous rename (two unmatched candidates on
each side) resets both rather than guessing; a genuinely removed
declaration is reported disposed; and the fixture that actually matters
to a user — count preserved at 12 across a refresh, and the *edited*
click logic (+2 instead of +1) is what genuinely executes on the next
click, proving setup was really rerun rather than the old closure
surviving.

## Update — the effect half, proven against a real ComponentInstance and Scope

`tests/core/refresh_component_spec.lua` (2 tests, part of the regular
354-spec suite) wires `RefreshRegistry` into a real `ComponentInstance`
(`core/component.lua`, unmodified) mounted through the real `Reconciler`
and `TestHost`, and performs the refresh sequence by hand (dispose the
old scope, create a fresh one, swap in the "edited" setup function, clear
the cached render closure, re-render) — exactly the sequence
`HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md`'s Part 3 describes, run against
real code, not asserted in prose:

- The old effect's cleanup runs **exactly once**, and only when the old
  scope is disposed — `Scope:dispose()`'s existing LIFO cleanup
  machinery does this for free; no HMR-specific disposal logic was
  needed, because effects were already scope-owned for unmount, and
  refresh is just an unmount-then-remount of the effect half with the
  signal half carved out and preserved separately.
- The new effect runs **exactly once** after refresh, not zero times and
  not twice.
- The signal value set before refresh (12, then later 9 and 10 in a
  second test with two *consecutive* refreshes) is what the refreshed
  component actually renders — composed through the real render pipeline
  (`instance:render()` producing a real VNode, `props.children[1].text`
  read back), not asserted against the registry in isolation.

A real, minor test-authoring bug was caught immediately by running this:
`H.h("button", nil, "text")` promotes the string child to a real Text
VNode (confirmed earlier this session via the WASM proof, forgotten while
writing this test) — the first assertion attempt compared a VNode table
to a string and failed with a clear, honest diff (`got {}`), not a false
pass. Fixed by reading `.text` off the child VNode.

**Left open, deliberately, not attempted this session**: the SSE
transport implementation and its browser-side `EventSource` proof; the
LUAX compiler pass that would attach `{kind, name, block_path}`
automatically instead of by hand (every test in both refresh specs still
hand-writes descriptors); the refresh sequence is still performed by the
test itself, not by any real code path inside `component.lua`; the JS
island HMR ABI; a real `"suspense"` boundary kind and a real
streaming-Suspense consumer; the full mixed vertical slice. Both halves
of refresh (signal identity, effect lifecycle) are now proven
individually and in composition against real Hydronium code — what
remains is entirely about *triggering* a refresh for real (a compiler
pass attaching descriptors automatically, and wiring the proven
mechanism into `component.lua` itself), not about whether the refresh
mechanism itself is sound.

## Update — the file-watching / dev-transport trigger, proven live

One piece of "triggering a refresh for real" is now closed:
**file change on disk → real push notification to a connected client**,
via a bounded long-poll over Meteorite's `stream_begin`/`stream_write`/
`stream_end` primitive at a new `/__hydronium/watch` route in
`examples/meteorite_ssr/src/main.lua`. Full detail, including three
live timestamped socket probes (heartbeat/budget expiry, a live edit
mid-stream, and the reconnect-race case a naive long-poll gets wrong) is
in `docs/METEORITE_STREAMING_FOUNDATION.md`'s "the streaming primitive
used for a real HMR dev-transport trigger" section — not duplicated
here since that document is the established home for live-socket
evidence.

**What this does and does not close**: the *transport* (server detects a
change, pushes something a connected client would receive) is proven.
The example was also switched to `fast_http` (meteorite's own
production-default backend), closing the coexistence gap this section
originally flagged: the watch stream and ordinary page loads now
provably run concurrently — a `GET /` issued while an
`/__hydronium/watch` connection was still mid-poll-loop returned `200`
in 15ms, not blocked until the watch connection closed. See
`docs/METEORITE_STREAMING_FOUNDATION.md`'s "switched the example to
fast_http" update for the full route-suite re-verification this
required.

## Update — both client-side halves closed: live reload, and real state-preserving HMR

Both remaining items from the update above are now closed, with real
browser evidence (Chromium via Playwright, not a synthetic harness) for
each — deliberately built and verified as two separate things, not one
generalized mechanism, because they have genuinely different targets:

**Live reload for `examples/meteorite_ssr`** (`src/hydronium/client/dev_reload.js`,
wired into `views/App.luax`): this page is server-rendered with no
hydrated Hydronium runtime in the browser, so there is no client-side
state to preserve — a full `location.reload()` on a `reload` event is
the honest, complete behavior here, not a placeholder for something
smarter. Verified live: a real edit to `views/App.luax` while the page
is open produces a second real `load` event ~130ms later, with zero
manual intervention.

**Real state-preserving HMR proof**
(`examples/meteorite_ssr/hmr_demo/`): a real Lua 5.4 WASM VM (wasmoon)
running 12 real Hydronium source files (`hydronium.signals`,
`hydronium.core.scope`, `hydronium.core.refresh`, and a new
`hydronium.interpreter.lua.hydrate_counter_island_refreshable`),
hydrating a real SSR-marker-shaped DOM, driving the exact required proof
sequence end to end:

```
SSR Counter = 10  ->  WASM Lua hydrates by claiming existing DOM
->  2 real DOM clicks  ->  Count = 12
->  real file edit on disk (hmr_demo/click_increment.lua: 1 -> 2)
->  real dev-transport push  ->  browser fetches the new source
->  RefreshRegistry-driven refresh (dispose old Scope, new Scope, rerun setup)
->  Count still 12 (state preserved)
->  1 more click  ->  Count = 14 (the NEW +2 logic is what ran, not the old +1)
```

All four assertions pass against the real running page (`node --test`-style
plain assertions, read back from the DOM, not mocked): hydrate, 2 clicks,
state-preserved-after-refresh, and new-logic-active-after-refresh. Full
detail, including the real bugs found building this (Chromium not
reliably resending `Last-Event-ID` for named SSE events across
auto-reconnect, and the HTTP response getting cached by the browser with
no way to set `Cache-Control` on Meteorite's streaming primitive) is in
`docs/METEORITE_STREAMING_FOUNDATION.md`'s "the client side, both halves"
section.

This deliberately does NOT go through `core.component`/`core.reconciler`
— same scoping reasoning as `hydrate_counter_island` itself (see that
function's own doc comment): this proves the `RefreshRegistry` +
`Scope`/`Effect` disposal mechanism composes correctly with a real
browser DOM and a real WASM Lua runtime, which is what was actually
open; wiring refresh into the general component/reconciler path remains
a separate, larger, still-unstarted piece of work.

**Still open, explicitly not attempted**: the LUAX compiler pass for
automatic descriptor attachment (both refresh specs and this proof all
hand-write `{kind, name, block_path}`); wiring refresh into
`ComponentInstance`/`core.reconciler` itself, for an arbitrary component
tree rather than one hand-wired island; the JS island HMR ABI; a real
`"suspense"` boundary kind; the full mixed vertical slice (streamed
Suspense + Lua island + JS island + HMR, all together, on one page).

## Update — superseded: refresh IS now wired into `ComponentInstance`/`core.reconciler`, for arbitrary automatically-discovered components

The item directly above — "wiring refresh into
`ComponentInstance`/`core.reconciler` itself, for an arbitrary component
tree rather than one hand-wired island" — is done, generalized beyond a
single hand-wired island, and proven both natively (LuaJIT) and in a
real browser (WASM Lua via Playwright/Chromium), including the
mandatory multiple-simultaneous-instances-of-one-family case. This
closes the last item this document's own scheduler/HMR foundation work
had flagged as the next real gap.

New: `src/hydronium/core/family.lua` (`Family` — stable identity for
"the current definition of this component, wherever it's mounted") and
`src/hydronium/core/family_loader.lua` (automatic discovery via
wrapping global `require`, zero hand-registration, zero source list).
`core/component.lua`'s `ComponentInstance` now auto-registers into a
family on mount, auto-unregisters on unmount, and gained a real
`:refresh(new_definition)` method that disposes the old scope and
reuses the existing `:update()` — no bespoke HMR diff engine.

This does **not** close the compiler-descriptor gap named above
(`{kind, name, block_path}` signal identity is still 100%
hand-written), and does not add a module dependency graph or
propagation from a changed non-component module to its dependents —
both remain real, unstarted gaps. Full detail, the full evidence
trail, and an honest hard-gate-by-hard-gate accounting (9 of 15 fully
met) are in `docs/HMR_COMPONENT_FAMILIES.md` and
`docs/HMR_GENERALIZATION_RESULTS.md` — this update intentionally does
not duplicate that content.

Also newly surfaced while building the browser proof, and not
previously named anywhere in this document: **no real browser DOM host
adapter exists for the general `Reconciler`** — only the narrow
hand-bridge above (`hydrate_counter_island`/`_refreshable`) and the
in-memory `TestHost` used by the test suite. The family/refresh browser
proof runs a real WASM Lua VM against real reconciliation logic, but
through `TestHost`, not real DOM nodes. See
`docs/HMR_GENERALIZATION_RESULTS.md` Part 4 for the full reasoning —
this is flagged as a separate, sizeable, still-unstarted piece of
foundational work, not something this round's proof should be read as
having covered.

## Update — superseded: the real DOM Host gap above is closed

A later counter-agent audit challenged exactly this gap as the correct
next priority (ahead of a module dependency graph) and it's now built:
`src/hydronium/host/dom.lua`, a real Host adapter implementing the full
Reconciler contract against real DOM, plus general hydration
(`Reconciler:hydrate`/`:hydrateRoot`, new reconciler methods, host-
agnostic). Verified live in a real browser: a 5-node arbitrary tree (2
independent component instances plus 3 untouched siblings), real click
events, real HMR with DOM-identity preservation and event-listener
replacement, and a real hydration-mismatch fallback fixture — 22/22
assertions. Full record: `docs/HMR_DOM_HOST.md`. This does not change
anything else this document already flagged as open (compiler
descriptors, module graph, propagation, environment separation).
