--[[
  Hydronium Family Loader (HMR generalization) -- automatic
  ComponentFamily discovery and reload, with zero per-component
  registration calls.

  This is the piece that makes ComponentFamily identity "automatic"
  rather than hand-wired: it subscribes to the opt-in runtime module graph,
  which wraps global `require`, so that the FIRST time any module is loaded,
  its return value is scanned for candidate exports (a bare function, or a
  table of named functions). A candidate becomes a family only when it is
  mounted as a component, avoiding accidental HMR boundaries for ordinary
  utility exports. Its family key is
  `"<module_id>::<export_name>"` -- module_id being the exact string
  passed to `require(...)`, which is already the real, stable,
  relocatable "package/module logical path" the generalization mission
  calls for (not an absolute filesystem path, not a generated chunk
  name, not a hand-assigned label).

  `.reload(module_id)` is the dev-transport-triggered entry point: clear
  `package.loaded[module_id]`, require it again (forcing real
  re-execution of the real module body, the same "fresh Lua state sees
  fresh code" property every other part of this HMR effort has relied
  on), rescan its exports, and fan the new definition out to every
  matching family via Family:update_definition (which itself calls each
  live ComponentInstance's own :refresh()).

  Why global `require`, not a hand-called registration function: the
  generalization mission's hard requirement is that a normal component,
  required normally, is discovered without any source list or
  per-component registration call. Stock Lua/LuaJIT has exactly one
  hook point for "a module was just loaded for the first time":
  `require` itself. This is opt-in (call `.enable()`) precisely so
  production and any code that never calls it pays zero cost and sees
  zero behavior change -- the reverse map stays empty, and
  `core/component.lua`'s family lookup is then always a no-op.

  What this does NOT attempt (see docs/HMR_COMPONENT_FAMILIES.md for the
  full list): a local/anonymous component (never itself a module's
  top-level return value or a named table export) is never discovered
  here, so it never gets a family and never participates in automatic
  refresh -- not "guessed" via a weaker identity, simply not tracked, an
  explicitly safe default. No module dependency graph, no propagation
  from a changed non-component module to the components that use it
  (that is the separate, much larger, deliberately deferred piece of
  this mission).
--]]

local family = require("hydronium.core.family")
local module_graph = require("hydronium.core.module_graph")

local familyLoaderModule = {}

-- function/table value -> Family. Not weak: a family's
-- current_definition must stay resolvable via this map for as long as
-- any instance might still reference it, and reload() is the only
-- thing that ever needs to remove an entry (when a definition is
-- superseded), not the garbage collector.
local reverseMap = {}
local candidates = {}

local unsubscribe = nil
local enabled = false

--- Scans a just-loaded module's export shape for component-like values.
--- @param module_id string
--- @param exported any
--- @return { [string]: function } family_id -> definition, for every
---   component-shaped export found
local function scan_exports(module_id, exported)
  local found = {}
  if type(exported) == "function" then
    found[module_id .. "::default"] = exported
  elseif type(exported) == "table" then
    for key, value in pairs(exported) do
      if type(value) == "function" and type(key) == "string" then
        found[module_id .. "::" .. key] = value
      end
    end
  end
  return found
end

--- Enables automatic family discovery by wrapping the global `require`.
--- Idempotent -- safe to call more than once.
function familyLoaderModule.enable()
  if enabled then
    return
  end
  enabled = true

  module_graph.enable()
  unsubscribe = module_graph.on_load(function(event)
    if event.cache_hit then return end
    local found = scan_exports(event.module_id, event.value)
    for family_id, fn in pairs(found) do
      -- An exported function is only a *candidate*.  It becomes a component
      -- boundary when ComponentInstance mounts it through lookup(), rather
      -- than making every helper function in a table export HMR-eligible.
      candidates[fn] = { family_id = family_id, module_id = event.module_id }
    end
  end)
end

--- Test-only: removes family discovery and clears its tracking state. The
--- shared module_graph owns the require wrapper and may remain enabled.
--- Never call this in real application/dev code.
function familyLoaderModule.reset()
  if unsubscribe then unsubscribe() end
  unsubscribe = nil
  enabled = false
  reverseMap = {}
  candidates = {}
end

--- @param fn function|table
--- @return Family?
function familyLoaderModule.lookup(fn)
  local known = reverseMap[fn]
  if known then return known end
  local candidate = candidates[fn]
  if not candidate then return nil end
  local family_id = candidate.family_id
  local fam = family.get_or_create(family_id)
  if fam.current_definition == nil then fam.current_definition = fn end
  reverseMap[fn] = fam
  module_graph.register_family(candidate.module_id, family_id)
  return fam
end

local function scan_staged(module_id, exported)
  local found = scan_exports(module_id, exported)
  for family_id, fn in pairs(found) do
    candidates[fn] = { family_id = family_id, module_id = module_id }
  end
  return found
end

--- Evaluate modules without refreshing any live component.  Call commit()
--- only after every staged module succeeded, so a compilation/evaluation
--- failure cannot dispose an already-live component scope.
function familyLoaderModule.stage(module_ids)
  local staged = { modules = {}, previous_loaded = {} }
  for _, module_id in ipairs(module_ids) do
    staged.previous_loaded[module_id] = package.loaded[module_id]
    package.loaded[module_id] = nil
    local ok, value = pcall(module_graph.require, module_id)
    if not ok then
      for restored_id, previous in pairs(staged.previous_loaded) do
        package.loaded[restored_id] = previous
      end
      return nil, tostring(value)
    end
    staged.modules[module_id] = value
  end
  return staged
end

--- Commit previously staged module values and refresh their already-mounted
--- families. This is intentionally the first point at which live scopes can
--- change.
function familyLoaderModule.commit(staged)
  local results = {}
  for module_id, exported in pairs(staged.modules) do
    local found = scan_staged(module_id, exported)
    for family_id, fn in pairs(found) do
      local fam = family.get(family_id)
      -- Keep a zero-instance record in the report for a newly exported
      -- component. It becomes a graph boundary only after a mount registers
      -- it through lookup().
      if not fam then fam = family.get_or_create(family_id) end
      reverseMap[fn] = fam
      results[family_id] = fam:update_definition(fn)
    end
  end
  return results
end

--- Dev-transport-triggered reload: forces real re-execution of
--- `module_id`'s body, rescans its exports, and refreshes every live
--- mounted instance of every family it defines.
--- @param module_id string
--- @return { [string]: table } family_id -> Family:update_definition()'s result
function familyLoaderModule.reload(module_id)
  local staged, err = familyLoaderModule.stage({ module_id })
  if not staged then
    error("family_loader.reload: failed to reload '" .. tostring(module_id) .. "': " .. err, 0)
  end
  return familyLoaderModule.commit(staged)
end

return familyLoaderModule
