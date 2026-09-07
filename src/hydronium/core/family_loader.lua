--[[
  Hydronium Family Loader (HMR generalization) -- automatic
  ComponentFamily discovery and reload, with zero per-component
  registration calls.

  This is the piece that makes ComponentFamily identity "automatic"
  rather than hand-wired: it wraps the global `require` (opt-in only,
  via `.enable()`, never on by default -- see "why global require" below)
  so that the FIRST time any module is loaded, its return value is
  scanned for component-shaped exports (a bare function, or a table of
  named functions) and each one is registered as a family keyed by
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

local familyLoaderModule = {}

-- function/table value -> Family. Not weak: a family's
-- current_definition must stay resolvable via this map for as long as
-- any instance might still reference it, and reload() is the only
-- thing that ever needs to remove an entry (when a definition is
-- superseded), not the garbage collector.
local reverseMap = {}

local original_require = require
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

  _G.require = function(modname)
    local already_loaded = package.loaded[modname] ~= nil
    local result = original_require(modname)
    if not already_loaded then
      local found = scan_exports(modname, result)
      for family_id, fn in pairs(found) do
        local fam = family.get_or_create(family_id)
        fam.current_definition = fn
        reverseMap[fn] = fam
      end
    end
    return result
  end
end

--- Test-only: restores the original `require` and clears all tracking
--- state. Never call this in real application/dev code.
function familyLoaderModule.reset()
  if enabled then
    _G.require = original_require
    enabled = false
  end
  reverseMap = {}
end

--- @param fn function|table
--- @return Family?
function familyLoaderModule.lookup(fn)
  return reverseMap[fn]
end

--- Dev-transport-triggered reload: forces real re-execution of
--- `module_id`'s body, rescans its exports, and refreshes every live
--- mounted instance of every family it defines.
--- @param module_id string
--- @return { [string]: table } family_id -> Family:update_definition()'s result
function familyLoaderModule.reload(module_id)
  package.loaded[module_id] = nil
  local ok, new_export = pcall(original_require, module_id)
  if not ok then
    error("family_loader.reload: failed to reload '" .. tostring(module_id) .. "': " .. tostring(new_export), 0)
  end

  local found = scan_exports(module_id, new_export)
  local results = {}
  for family_id, fn in pairs(found) do
    local fam = family.get_or_create(family_id)
    reverseMap[fn] = fam
    results[family_id] = fam:update_definition(fn)
  end
  return results
end

return familyLoaderModule
