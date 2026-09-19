-- Runtime observations of managed Lua module loading.
--
-- This is deliberately an observation-only primitive.  It records the
-- require edges the current VM actually takes (including cache hits), but it
-- never chooses an invalidation policy or changes package loading semantics.

local M = {}

local original_require = require
local enabled = false
local stack = {}
local modules = {}
local listeners = {}

local function module_for(id)
  local entry = modules[id]
  if not entry then
    entry = {
      id = id,
      dependencies = {},
      importers = {},
      families = {},
      generation = 0,
      revision = nil,
      -- "observed" means the VM saw this module through require, but has no
      -- source-manifest guarantee.  Hosts/build tooling may promote it to
      -- "managed" with manage().
      coverage = "observed",
    }
    modules[id] = entry
  end
  return entry
end

local function notify(event)
  for _, listener in pairs(listeners) do
    listener(event)
  end
end

--- Mark a module as source-managed by a host/build manifest.  This only
--- annotates observations; it does not load or reload the module.
function M.manage(module_id, opts)
  if type(module_id) ~= "string" or module_id == "" then
    error("hydronium.core.module_graph: module_id must be a non-empty string", 2)
  end
  opts = opts or {}
  local entry = module_for(module_id)
  entry.coverage = opts.coverage or "managed"
  if opts.revision ~= nil then entry.revision = opts.revision end
  return entry
end

--- Return the mutable observation record for one module, if known.
function M.get(module_id)
  return modules[module_id]
end

--- Return all observed module records.  Callers must treat this as read-only.
function M.all()
  return modules
end

--- Associate a mounted component-family identity with the module that
--- exported it.  This is descriptive data for planning only.
function M.register_family(module_id, family_id)
  module_for(module_id).families[family_id] = true
end

local function sorted_keys(set)
  local out = {}
  for key in pairs(set) do table.insert(out, key) end
  table.sort(out)
  return out
end

--- Produce a deterministic, side-effect-free update decision from observed
--- runtime edges. `opts.root` is an explicit host remount boundary; without
--- one, an affected graph with no mounted component family must restart.
---
--- The returned `modules` list is dependency-first for the affected region,
--- making it suitable for staged evaluation. Cycles are deliberately a
--- restart outcome: this phase does not guess a partial refresh order.
function M.plan(changed, opts)
  opts = opts or {}
  if opts.rejected then
    return { outcome = "rejected", modules = {}, families = {}, reason = tostring(opts.rejected) }
  end
  if type(changed) ~= "table" then
    error("hydronium.core.module_graph: changed must be an array of module ids", 2)
  end

  local changed_set, affected = {}, {}
  for _, id in ipairs(changed) do
    if type(id) ~= "string" or id == "" then
      error("hydronium.core.module_graph: changed module ids must be non-empty strings", 2)
    end
    changed_set[id], affected[id] = true, true
  end

  local pending = sorted_keys(changed_set)
  local cursor = 1
  while pending[cursor] do
    local id = pending[cursor]
    cursor = cursor + 1
    local entry = modules[id]
    if entry then
      for importer in pairs(entry.importers) do
        if not affected[importer] then
          affected[importer] = true
          table.insert(pending, importer)
        end
      end
    end
  end

  local all_unloaded = true
  for id in pairs(changed_set) do
    if package.loaded[id] ~= nil then all_unloaded = false break end
  end
  if all_unloaded then
    return { outcome = "installed", modules = sorted_keys(changed_set), families = {} }
  end

  for id in pairs(affected) do
    local entry = modules[id]
    if not entry or entry.coverage == "opaque" then
      return { outcome = "restart", modules = sorted_keys(affected), families = {}, reason = "opaque_module:" .. id }
    end
  end

  local marks, ordered, cyclic = {}, {}, false
  local function visit(id)
    if marks[id] == "visiting" then cyclic = true return end
    if marks[id] then return end
    marks[id] = "visiting"
    local entry = modules[id]
    if entry then
      for _, dep in ipairs(sorted_keys(entry.dependencies)) do
        if affected[dep] then visit(dep) end
      end
    end
    marks[id] = "done"
    table.insert(ordered, id)
  end
  for _, id in ipairs(sorted_keys(affected)) do visit(id) end
  if cyclic then
    return { outcome = "restart", modules = sorted_keys(affected), families = {}, reason = "cycle" }
  end

  local families = {}
  for id in pairs(affected) do
    local entry = modules[id]
    if entry then for family_id in pairs(entry.families) do families[family_id] = true end end
  end
  local family_list = sorted_keys(families)
  if #family_list > 0 then
    return { outcome = "hot", modules = ordered, families = family_list }
  end
  if opts.root then
    return { outcome = "remount", modules = ordered, families = {}, root = opts.root }
  end
  return { outcome = "restart", modules = ordered, families = {}, reason = "no_component_boundary" }
end

--- Subscribe to successful require observations.  Used by family_loader to
--- discover potential component exports without installing a competing
--- require wrapper.  Returns an unsubscribe function.
function M.on_load(listener)
  if type(listener) ~= "function" then
    error("hydronium.core.module_graph: listener must be a function", 2)
  end
  local token = {}
  listeners[token] = listener
  return function() listeners[token] = nil end
end

local function observed_require(module_id)
  local parent_id = stack[#stack]
  local entry = module_for(module_id)
  if parent_id then
    local parent = module_for(parent_id)
    parent.dependencies[module_id] = true
    entry.importers[parent_id] = true
  end

  local cache_hit = package.loaded[module_id] ~= nil
  table.insert(stack, module_id)
  local results = { pcall(original_require, module_id) }
  table.remove(stack)
  if not results[1] then
    error(results[2], 0)
  end

  if not cache_hit then entry.generation = entry.generation + 1 end
  local event = {
    module_id = module_id,
    value = results[2],
    cache_hit = cache_hit,
    generation = entry.generation,
    coverage = entry.coverage,
  }
  notify(event)
  return unpack(results, 2)
end

--- Load one module through the graph.  This is also useful to code that must
--- force a real require after editing package.loaded (such as HMR transport).
function M.require(module_id)
  return observed_require(module_id)
end

--- Begin recording require edges globally.  Idempotent and opt-in.
function M.enable()
  if enabled then return end
  enabled = true
  _G.require = observed_require
end

function M.is_enabled()
  return enabled
end

--- Test-only reset.  Real applications should leave observations alive for
--- the VM lifetime so the graph remains an accurate loading history.
function M.reset()
  if enabled then
    _G.require = original_require
    enabled = false
  end
  stack = {}
  modules = {}
  listeners = {}
end

return M
