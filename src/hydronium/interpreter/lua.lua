--[[
  hydronium.interpreter.lua -- the client-side Lua execution backend for
  `d.lua.island` (see hydronium/dom/init.lua and
  docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md). NOT the DOM authoring surface
  itself -- `d.lua.island` is a DOM-bound descriptor selecting this
  backend; this module is the backend it selects.

  v1 scope, deliberately narrow (mission Part XXII step 4: "one Lua WASM
  Counter hydration proof", not a general hydration algorithm):
  `hydrate_counter_island` claims exactly the DOM shape a single
  `<d.lua.island><Counter .../></d.lua.island>` SSR boundary produces --
  one island containing one <button> -- and wires one real Hydronium
  signal to it. There is no VNode-tree reconciliation, no arbitrary
  component support, no re-entry into `hydronium.core.reconciler` (which
  still has no client host for ISLAND-kind vnodes at all -- see
  core/reconciler.lua). Building the general algorithm ahead of a second,
  differently-shaped proof would be exactly the kind of speculative work
  this project avoids; this function exists to be outgrown, not extended
  in place.

  Host contract (must be provided as plain Lua globals by whatever
  embeds this WASM Lua VM -- e.g. wasmoon in a browser page -- before
  calling into this module; see the published "Hydronium in WASM" proof
  artifact for a concrete host implementation):

    hy_find_island(island_id: string) -> handle | nil
      Locate the DOM range between the `<!--hy:i:<island_id>:lua-->` and
      `<!--hy:/i:<island_id>-->` comment markers a real SSR render emitted
      (see server/init.lua's ISLAND handling) and return an opaque handle
      for it, or nil if not found. Must NOT create any DOM node -- this is
      the "claim existing DOM, don't rebuild it" half of hydration
      (mission invariant #41).
    hy_query_button(handle) -> handle | nil
      Find the <button> element within an island handle's range.
    hy_get_text(handle) -> string
    hy_set_text(handle, text: string)
    hy_on_click(handle, callback: fun())
      Attach a real DOM click listener that invokes `callback` (a Lua
      function, called back into this same VM) when fired.

  All handles are opaque to Lua -- this module never inspects them, only
  passes them back to the host functions above. What a "handle" actually
  is (an index into a host-side registry, a wrapped userdata, ...) is a
  host implementation detail this module does not depend on.
--]]

local signals = require("hydronium.signals")

local M = {}

--- Hydrates a single `<d.lua.island>` boundary known to contain exactly
--- one `<Counter initial={N}/>`-shaped `<button>`.
--- @param island_id string The island id from the SSR client plan (e.g. "hy:i1")
--- @param initial number Starting count -- MUST match what SSR actually rendered;
---   this function does not read the DOM's current text as its source of truth,
---   matching real hydration (state comes from the component, not scraped HTML).
--- @return table { get = fun(): number } for the resulting reactive count, for
---   the caller (e.g. a test/proof harness) to inspect without a second DOM read.
function M.hydrate_counter_island(island_id, initial)
  local island = hy_find_island(island_id)
  if not island then
    error("hydronium.interpreter.lua: no DOM found for island `" .. tostring(island_id) .. "`", 2)
  end

  local button = hy_query_button(island)
  if not button then
    error("hydronium.interpreter.lua: island `" .. tostring(island_id) .. "` has no <button> to hydrate", 2)
  end

  local count, setCount = signals.createSignal(initial)

  -- Real Hydronium reactivity, not a hand-called render() function: this
  -- effect re-runs (and only this line re-runs) whenever `count` changes,
  -- exactly as it would for any other Hydronium signal consumer.
  signals.createEffect(function()
    hy_set_text(button, "Count: " .. tostring(count()))
  end)

  hy_on_click(button, function()
    setCount(count() + 1)
  end)

  return { get = count }
end

return M
