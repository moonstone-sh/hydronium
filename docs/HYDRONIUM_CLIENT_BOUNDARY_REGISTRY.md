# Client Boundary Registry — Extracted, Migrated, Verified

This describes real, built, tested code — unlike most of
`HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md`, which is design/verification
work. `src/hydronium/client/boundary_registry.js` exists, both real
consumers use it, the duplicated code it replaced is deleted, and 14
permanent tests plus a separate real-DOM (jsdom) verification pass all
pass.

## 1. The duplication, proven from code before extracting

| Operation | `bootstrap.js` (before) | Published WASM proof (before) |
|---|---|---|
| find start/end comment markers | `findIslandRange(doc, root, id)` — `TreeWalker` + `SHOW_COMMENT`, matches `hy:i:${id}:js`/`hy:i:${id}:lua` then `hy:/i:${id}` | `findIsland(islandId)` — identical `TreeWalker` logic, matching only `:lua` (Lua-only proof) |
| element children of a range | `rangeElements(range)` — walk `.nextSibling` from `start`, collect `nodeType === 1` | `queryButton(handle)` — same walk, but also does a nested `querySelector("button")` per element |
| return shape | raw `{ start, end }` object | opaque integer handle into a local array (needed to cross the Lua/WASM boundary) |

Nearly identical traversal logic, independently written, differing only
in return shape and one incidental detail (`:js` matching). This is what
Part II §2 of the mission asked to prove from code, not assert — done.

## 2. What was extracted: `ClientBoundaryRegistry`

`src/hydronium/client/boundary_registry.js`. Scope is deliberately
narrow — built to what the two real consumers need plus what a
concretely-anticipated third consumer (a future streaming patcher or HMR
coordinator) would need with the *same* marker semantics, not a
speculative full API:

- `discover(root, id, kind = "island")` — finds and registers a
  boundary's markers, or returns `null` if genuinely not present (not an
  error — the SSR segment may not have arrived yet). Throws on malformed
  markers: a start with no matching end, or a duplicate start for the
  same id. This is the concrete mechanism behind "fail explicitly in
  development instead of silently mutating an arbitrary nearby range."
- `elements(id)` — the element children within a boundary's range, in
  order. Supports ranges with zero elements (text-only), one, or many —
  the abstraction was never `boundary = HTMLElement`.
- `claim(id, owner)` / `release(id, owner)` — ownership. Idempotent for
  the same owner; throws for a conflicting different owner. This is a
  real invariant now, not a documented intention: two independent patch
  mechanisms cannot both believe they own the same boundary, because the
  second one's `claim()` call throws.
- `generation(id)` / `advanceGeneration(id)` / `isStale(id, gen)` — the
  smallest possible staleness model: an integer per boundary, compared
  before any mutation would be applied. An unknown boundary is treated
  as stale (nothing safe to mutate).
- `markFinalized(id)`, `dispose(id)`, `has(id)`, `find(id)` round out the
  state machine: `present → claimed → finalized`, plus `dispose` to
  forget a boundary entirely.

**Deliberately not implemented**: a `"suspense"` boundary kind, a
`"declared"`/`"pending"` pre-DOM state, and DOM-range replacement
(`replace_range`). No real consumer exists for any of these yet — adding
them now would be exactly the "implement methods without actual
consumers" the mission's own Part II §6 warns against. The `kind`
parameter already accepts any string (a `"root"` boundary for
`d.lua.mount` works today, tested below), so extending to a real
`"suspense"` kind later is additive, not a redesign.

## 3. Both real consumers migrated, duplication deleted

- `src/hydronium/client/bootstrap.js` no longer contains
  `findIslandRange`/`rangeElements` — it imports the registry and calls
  `discover`/`elements`, and now also calls `claim(id, "js-bootstrap")`
  before hydrating and `release` in `disposeIsland`. Re-verified against
  the exact same jsdom-based end-to-end test used before the migration
  (real SSR shape, real dynamic import of the real `counter.js`, real
  dispatched clicks, real `dispose()`) — identical pass, same output.
- The published "Hydronium in WASM" artifact (same URL as all prior
  updates) no longer contains its own `findIsland`/`queryButton` DOM
  traversal — it embeds `boundary_registry.js` **verbatim** (the exact
  real file content, `export` keywords mechanically stripped since the
  artifact isn't an ES-module import target, not a hand-copied
  approximation — this is the same "embed the real file" technique
  already used for the Lua source files), and its `findIsland`/
  `queryButton` bridge functions are now a thin adapter calling
  `discover`/`elements`/`claim`. Re-verified two ways, matching the
  session's own established discipline of testing the exact code, not an
  equivalent stand-in: (a) the Lua-side flow, unaffected by this change,
  re-run against real wasmoon — still produces `Count: 10` → click →
  `Count: 11`; (b) the migrated JS-side bridge functions, extracted and
  run against a real DOM (jsdom) with the real SSR marker shape — finds
  the island, claims it, and a **second** claim attempt by a different
  owner is confirmed to throw with a message naming both owners. Neither
  consumer keeps a compatibility wrapper around the old traversal; it no
  longer exists.

## 4. Test matrix — 14 permanent tests, 37 additional jsdom checks

`tests/client/boundary_registry.test.mjs` (`node --test`, zero new
dependencies — a minimal hand-rolled DOM stand-in, not jsdom, since this
is the first JS code in an otherwise Lua-first framework and a real
dependency for one test file would be a bigger footprint change than the
module itself): root/island discovery, sibling islands, nested islands,
text-only ranges, multi-element ranges, missing closing marker (throws),
duplicate id (throws), every query method against an unknown id (safe,
non-throwing), claim/release/double-claim/re-claim-after-release, claim
on an unknown id (throws), generation advance and stale rejection,
dispose, `markFinalized` on an unknown id (safe no-op), and a `"root"`
kind boundary using the same mechanism. All 14 pass.

A separate, more exhaustive pass (37 checks) was run against real jsdom
during development to build confidence against actual `TreeWalker`
semantics before committing to the hand-rolled-DOM test file; not kept
as a permanent suite (no jsdom dependency in the repo), but the exact
script is referenced in this session's record for anyone who wants to
rerun it.

## 5. What this does not settle

No streaming-Suspense consumer exists yet to prove `replace_range` or a
`"suspense"` kind against — the registry's shape was designed to
*support* that without another marker-format change, but "would support"
is not "proven by a real consumer," and this document doesn't claim
otherwise. No HMR coordinator exists yet either. Both remain real,
separate, future work.
