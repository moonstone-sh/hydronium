--[[
  Hydronium HMR Refresh Registry.

  Implements the structural-matching resource-identity model from
  docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md against the REAL
  hydronium.signals primitives, keyed on {kind, name, block_path}
  descriptors attached to each `scope.refresh_registry:signal(...)`
  call site.

  Wiring status (verified against the code, not assumed -- keep this
  block honest if any of the three changes):

    * Component runtime -- WIRED, and load-bearing. Every
      ComponentInstance owns one RefreshRegistry for its whole
      lifetime (hydronium.core.component `.new()`, which sets both
      `self.refresh_registry` and `self.scope.refresh_registry`), and
      the runtime brackets each one-time setup call with
      :begin_generation() / :finish_generation() around
      `self.type(self.props, self.scope)`. `ComponentInstance:refresh()`
      deliberately does NOT recreate the registry -- that persistence
      is exactly what carries state across a hot swap. Component code
      never calls begin/finish_generation itself.

    * LUAX compiler -- WIRED. `hydronium_luax.transforms.refresh`
      rewrites a recognized `local x, setX = hydronium.signal(v)` at the
      top level of a component setup function into the descriptor-
      carrying `scope.refresh_registry:signal(v, {...})` form, so
      ordinary component source gets state preservation without hand-
      written descriptors. The pass is deliberately conservative: any
      call site it does not positively recognize is emitted unchanged
      and simply never participates in refresh matching.

    * Dev transports -- WIRED for declared component modules. The browser
      client maps changed paths through explicit update policies and calls
      `hydronium.core.hmr.replace` inside the surviving Wasmoon VM. The Ink
      create template uses the same primitive from its terminal event loop.
      Shared non-component dependency propagation still has no module graph;
      those edits require a broader fallback rather than a guessed refresh.

  Correction found while building this: earlier design language (this
  session's own prior document) referred to `scope:signal(initial)` as
  Hydronium's existing API. It is not -- `hydronium.core.scope.Scope` has
  no signal registry at all (only `Effect` ties itself to the ambient
  scope, via `scope:defer`, for disposal). The real API is the free
  function `hydronium.signals.createSignal(initial)`. This module wraps
  that real function; it does not invent a new one that doesn't exist.

  Design note on WHY signals are always freshly created and then
  value-copied, never returned-by-reference across generations: the
  matching decision for a "rename" candidate cannot be made until the
  *entire* new setup run has finished (you need to see every new
  declaration to know there's exactly one unmatched leftover on each
  side -- see :finish_generation()). But :signal() must return something
  valid to its caller immediately, before that information exists. So
  every call always creates a real, fresh signal (correct immediately,
  no special-casing at call time); finish_generation() then copies the
  matched old value into the new signal's underlying storage in place.
  Lua tables are references, so this mutation is visible to any closure
  that already captured the accessor -- as long as it happens before the
  next read, which it does (finish_generation runs immediately after the
  setup call returns, before any render/read).
--]]

local signals = require("hydronium.signals")

local M = {}

local RefreshRegistry = {}
RefreshRegistry.__index = RefreshRegistry

function RefreshRegistry.new()
  return setmetatable({
    generation = 0,
    records = {},        -- key -> record, committed after finish_generation()
    unmatched_old = {},  -- key -> record, old records not yet claimed this generation
    pending_new = {},     -- key -> record, this generation's not-yet-resolved declarations
  }, RefreshRegistry)
end

local function key_for(descriptor)
  return descriptor.kind .. "\0" .. descriptor.name .. "\0" .. descriptor.block_path
end

--- Call once at the start of each setup run (including the very first
--- one, which is just a refresh against an empty registry).
function RefreshRegistry:begin_generation()
  self.generation = self.generation + 1
  self.unmatched_old = self.records
  self.records = {}
  self.pending_new = {}
end

--- The refresh-aware replacement for `signals.createSignal(initial)`.
--- `descriptor = { kind = "signal", name = "count", block_path = "..." }`.
--- Always returns a real, freshly-created signal -- see the module doc
--- comment for why matching is resolved later, not here.
function RefreshRegistry:signal(initial, descriptor)
  local accessor, setter = signals.createSignal(initial)
  local key = key_for(descriptor)
  local rec = {
    kind = descriptor.kind,
    name = descriptor.name,
    block_path = descriptor.block_path,
    accessor = accessor,
    setter = setter,
  }
  self.records[key] = rec
  self.pending_new[key] = rec
  return accessor, setter
end

--- Call once after the new setup run completes. Resolves matches
--- (primary key match, then the rename heuristic for leftovers) and
--- copies matched old values into the new signals in place.
--- @return table report { preserved = {name,...}, renamed = {"new -> old",...}, created = {name,...}, disposed = {name,...} }
function RefreshRegistry:finish_generation()
  local report = { preserved = {}, renamed = {}, created = {}, disposed = {} }

  -- Primary pass: exact (kind, name, block_path) match.
  for key, new_rec in pairs(self.pending_new) do
    local old = self.unmatched_old[key]
    if old and old.kind == new_rec.kind then
      new_rec.accessor._signal.value = old.accessor._signal.value
      self.unmatched_old[key] = nil
      self.pending_new[key] = nil
      table.insert(report.preserved, new_rec.name)
    end
  end

  -- Secondary pass: rename heuristic. Group whatever is left, by kind.
  local leftover_by_kind = {}
  for _, rec in pairs(self.unmatched_old) do
    leftover_by_kind[rec.kind] = leftover_by_kind[rec.kind] or {}
    table.insert(leftover_by_kind[rec.kind], rec)
  end
  local pending_by_kind = {}
  for key, rec in pairs(self.pending_new) do
    pending_by_kind[rec.kind] = pending_by_kind[rec.kind] or {}
    table.insert(pending_by_kind[rec.kind], { key = key, rec = rec })
  end

  for kind, pendings in pairs(pending_by_kind) do
    local leftovers = leftover_by_kind[kind]
    if leftovers and #leftovers == 1 and #pendings == 1 then
      -- Exactly one unmatched candidate on each side of the same kind:
      -- a confident rename match. Never guess when there is more than
      -- one candidate on either side -- see the `else` branch.
      local old = leftovers[1]
      local new_entry = pendings[1]
      new_entry.rec.accessor._signal.value = old.accessor._signal.value
      table.insert(report.renamed, new_entry.rec.name .. " <- " .. old.name)
      self.pending_new[new_entry.key] = nil
      leftover_by_kind[kind] = {}
    else
      for _, p in ipairs(pendings) do
        table.insert(report.created, p.rec.name)
        self.pending_new[p.key] = nil
      end
    end
  end

  -- Anything still unmatched on the old side was genuinely removed (or
  -- was ambiguous and safely left unmatched rather than guessed).
  -- hydronium.signals has no disposal concept for signals today (only
  -- Effects are scope-disposed) -- there is nothing to explicitly clean
  -- up here; this only exists to report what happened.
  for kind, leftovers in pairs(leftover_by_kind) do
    for _, rec in ipairs(leftovers) do
      table.insert(report.disposed, rec.name)
    end
  end

  self.unmatched_old = {}
  self.pending_new = {}
  return report
end

M.RefreshRegistry = RefreshRegistry
return M
