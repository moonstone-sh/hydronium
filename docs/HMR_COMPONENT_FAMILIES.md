# Hydronium ComponentFamily + family_loader (Ground Truth)

What this document covers is real and shipped:
`src/hydronium/core/family.lua`, `src/hydronium/core/family_loader.lua`,
and the automatic wiring into `src/hydronium/core/component.lua`. It
does not cover a module dependency graph, compiler-emitted descriptors,
or propagation from a changed non-component module to the components
that use it — none of that exists yet. See
`docs/HMR_GENERALIZATION_RESULTS.md` for the full honest accounting of
what this session did and did not build.

## The problem this solves

Before this work, `core/component.lua`'s `ComponentInstance.type` was
simply whatever raw Lua function or table was passed to
`h(Component, props)` at the call site. There was no notion of "this is
a newer version of the same component" — every one of this whole HMR
effort's prior proofs (`RefreshRegistry`, `hydrate_counter_island_refreshable`)
worked by having a human (a test, or a hand-written demo bootstrap)
explicitly dispose the old scope, construct a new one, and call the new
definition directly. That is real and correctly proven, but it required
knowing, by name, which component to refresh — the opposite of what a
real HMR system needs.

## ComponentFamily

`hydronium.core.family`'s `Family` is stable identity for "the current
definition of this component, wherever it's mounted":

```lua
Family {
  id                 -- e.g. "app.components.counter::default"
  current_definition -- the function/table most recently registered
  generation         -- incremented on every update_definition() call
  instances          -- ComponentInstance -> true, explicit membership
  instance_count
}
```

`Family:register_instance(instance)` / `:unregister_instance(instance)`
are explicit, not a weak table — a family's `instances` must be an
immediately accurate answer to "who is mounted right now," not one that
depends on when the garbage collector next runs (this was a deliberate
correction from an earlier draft of this design).

`Family:update_definition(new_definition)` bumps `generation`, updates
`current_definition`, and calls `instance:refresh(new_definition)` on
every currently-registered instance, snapshotting the instance list
first (an instance's own refresh can mount/unmount other instances as
a side effect of reconciliation, which must not corrupt the iteration).

`familyModule.get_or_create(id)` / `.get(id)` / `.all()` / `.reset()`
(test-only) round out the registry's own API. There is exactly one
global registry (module-level `families` table) — not one per
environment or per root, which is a real, acknowledged simplification
(see "What this does not do" below).

## family_loader: automatic discovery, zero hand-wiring

This is the piece that makes family identity *automatic* rather than
requiring a registration call every component author would have to
remember to write. Family identity is derived from the real
`require()` module id (the exact string a real call site passes) plus
the export name — not a memory address, not a generated chunk filename,
not a line/column, not a hand-assigned label, per the generalization
mission's own explicit constraints.

**Why global `require`, not a registration function call:** the
mission's hard requirement is that a normal component, required
normally, is discovered without a source list or a per-component
registration call. Stock Lua/LuaJIT has exactly one hook point for "a
module was just loaded for the first time": `require` itself.
`family_loader.enable()` wraps it (opt-in — never called automatically,
so production and any code that never calls it pays zero cost and sees
zero behavior change: the reverse map stays empty, and
`core/component.lua`'s family lookup on every mount is then always a
cheap no-op table lookup returning `nil`).

```lua
familyLoader.enable()                 -- wrap global require (idempotent)
local Counter = require("app.components.counter") -- the real call site;
                                                    -- no registration call
familyLoader.lookup(Counter)          -- -> Family, or nil if not discovered
familyLoader.reload("app.components.counter") -- dev-transport-triggered:
                                                -- clear package.loaded,
                                                -- require again (forces
                                                -- real re-execution),
                                                -- rescan exports, fan out
                                                -- via Family:update_definition
```

`scan_exports(module_id, exported)` covers two shapes: a bare function
return (`family_id = module_id .. "::default"`) and a table of named
function exports (`family_id = module_id .. "::" .. key`, for each
string-keyed function value). Both are real, common Lua module shapes;
neither requires any compiler cooperation.

## Automatic wiring into ComponentInstance

`core/component.lua`'s `.new()`:

```lua
self.family = familyLoader.lookup(self.type)
if self.family then
  self.family:register_instance(self)
end
```

`:unmount()` mirrors this with an explicit `unregister_instance` call
before disposing the scope — deterministic, immediate, no stale
references (verified: `tests/core/family_hmr_spec.lua` asserts
`instance_count` drops correctly on unmount, independently per
instance).

## ComponentInstance:refresh() — reuses normal reconciliation, no bespoke diff engine

```lua
function ComponentInstance:refresh(new_definition)
  -- dispose the OLD scope (runs the old effect's cleanup exactly once,
  -- via Scope's own existing LIFO disposal machinery -- no new
  -- disposal logic needed, same finding as the single-instance proof)
  -- create a fresh scope, re-attach this instance's own refresh_registry
  -- swap self.type, clear self.renderFn (forces the next render() to
  -- treat this as an initial invocation -- reruns setup)
  -- reuse self:update(self.props, self.reconciler) for the actual
  -- re-render + reconcile, through the SAME reconciler every other
  -- update already goes through
end
```

This generalizes exactly the sequence
`tests/core/refresh_component_spec.lua` proved by hand for one
component, and satisfies the generalization mission's own explicit
requirement ("Do not build a bespoke HMR DOM diff engine") by
construction: the only new code is scope/type/renderFn bookkeeping;
the actual DOM update comes from calling the pre-existing `:update()`.

## One RefreshRegistry per instance, not one per family — a real bug avoided before it shipped

Every `ComponentInstance` now owns its own `hydronium.core.refresh.RefreshRegistry`
(created once in `.new()`, persisting across refreshes — it must
remember the previous generation's records to compare the next one
against), exposed to component code as `scope.refresh_registry`.
`render()` drives `begin_generation()`/`finish_generation()`
automatically around the setup call; component code only ever calls
`scope.refresh_registry:signal(initial, descriptor)`.

This is deliberately **one registry per instance**, not one shared per
family/module. Two mounted instances of the same component calling
`scope.refresh_registry:signal(initial, {kind="signal", name="count", block_path="Counter.setup"})`
with the *identical* descriptor would collide on the same registry key
if they shared one registry — corrupting each instance's state with
the other's. This was caught by reasoning about the design before
writing the test that would have caught it at runtime instead
(`tests/core/family_hmr_spec.lua`'s two-instance assertions exist
specifically to keep this invariant honest going forward).

## What this does NOT do

- **No module dependency graph.** A changed component's own module is
  discovered and refreshed correctly. A changed *non-component*
  dependency (a shared utility module) has no path to the components
  that use it — there is no graph tracking that relationship at all.
  See `docs/HMR_GENERALIZATION_RESULTS.md`.
- **No compiler-emitted descriptors.** Family identity comes from
  `require()`'s own module id, which is real and already stable, but
  it is not what the generalization mission's Part III describes
  (`ModuleDescriptor`/`ComponentDescriptor` emitted by the LUAX
  compiler). Signal-level identity (`{kind, name, block_path}`) is
  still 100% hand-written in every consumer, exactly as it was before
  this session — the still-open compiler pass this whole HMR effort has
  named since its first foundation document.
- **Local/anonymous components are not discovered.** A component
  defined inside another function (never itself a module's top-level
  return value or a named table export) never appears in
  `scan_exports`'s output, so it never gets a family and never
  participates in automatic refresh. This is a safe default, not a
  guess at a weaker identity: such a component simply does not
  auto-refresh, requiring a full reload to see its changes, which is
  the pre-existing, unchanged behavior for every component before this
  session, not a regression.
- **No compatibility/remount decision.** `refresh()` always attempts a
  refresh; there is no detection of "this change is incompatible,
  remount instead of refresh." An incompatible resource-shape change
  (e.g. a signal's `kind` changing) is already handled correctly at
  the `RefreshRegistry` level (a kind change never reuses an
  incompatible value, proven in `tests/core/refresh_spec.lua`), but
  nothing above that decides "give up and remount the whole
  component/island/root" for a more structural incompatibility.
- **One global family registry, not one per environment.** Server-Lua,
  client-Lua-in-WASM, and (eventually) client-JS all share the same
  `require()`/`package.loaded` namespace *within a single Lua VM
  instance* — which is already naturally how this separates in
  practice (a server request and a browser's WASM VM are different Lua
  states entirely), but nothing in `family.lua` itself enforces or
  labels this; it's an emergent property of Lua VM boundaries, not a
  designed feature.

## Verified evidence

- **Native (LuaJIT), mandatory multi-instance case**:
  `tests/core/family_hmr_spec.lua`, two specs, both passing as part of
  the regular 358-spec suite. Proves: automatic discovery via a plain
  `require()` call (no registration), shared family membership for two
  instances of the same export, independent state preservation across
  a real `family_loader.reload()`, the new logic genuinely executing
  (not a stale closure), and correct `instance_count` bookkeeping on
  unmount.
- **Real browser (Chromium via Playwright), same mandatory case**:
  `examples/meteorite_ssr/hmr_demo/family_proof.html`, driven by a real
  WASM Lua VM (wasmoon), a real file edit to
  `hmr_demo/family_counter.lua` on disk, the real
  `/__hydronium/watch` dev transport, and `family_loader.reload()`
  inside that VM. 11/11 assertions pass. Uses `hydronium.test.createTestHost`
  (the same fake host the native test and this whole codebase's
  reconciler-level tests already use), not real DOM elements — see
  "Real DOM host: a newly-surfaced, separate gap" in
  `docs/HMR_GENERALIZATION_RESULTS.md` for why, and what that does and
  does not mean for this evidence.
