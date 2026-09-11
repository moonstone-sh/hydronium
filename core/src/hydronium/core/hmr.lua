-- Host-neutral module replacement for a live Hydronium Lua VM.
--
-- Transports decide when source changed; hosts decide how to present success
-- or failure. This module owns only the transferable operation: compile a
-- replacement loader, install it under a stable require ID, reload its
-- component families, and summarize the refresh.
local family_loader = require("hydronium.core.family_loader")

local M = {}

local function compile(module_id, source)
  if type(module_id) ~= "string" or module_id == "" then
    error("hydronium.core.hmr: module_id must be a non-empty string", 3)
  end
  if type(source) ~= "string" then
    error("hydronium.core.hmr: source for '" .. module_id .. "' must be a string", 3)
  end
  local load_fn = loadstring or load
  local chunk, err = load_fn(source, "@" .. module_id)
  if not chunk then
    error("hydronium.core.hmr: could not compile '" .. module_id .. "': " .. tostring(err), 3)
  end
  return chunk
end

--- Installs source as a package.preload module without requiring it.
--- Enable family_loader before the module's first require if it should be hot.
function M.install(module_id, source)
  package.preload[module_id] = compile(module_id, source)
end

--- Replaces one already-loaded component module and refreshes its families.
--- Loader and package.loaded entries are restored if module evaluation fails.
function M.replace(module_id, source)
  local next_loader = compile(module_id, source)
  local previous_loader = package.preload[module_id]
  local previous_loaded = package.loaded[module_id]
  package.preload[module_id] = next_loader

  local ok, results = pcall(family_loader.reload, module_id)
  if not ok then
    package.preload[module_id] = previous_loader
    package.loaded[module_id] = previous_loaded
    error("hydronium.core.hmr: replacement of '" .. module_id .. "' failed: " .. tostring(results), 2)
  end

  local summary = { module = module_id, families = 0, refreshed = 0, failed = 0, results = results }
  for _, result in pairs(results) do
    summary.families = summary.families + 1
    summary.refreshed = summary.refreshed + (result.refreshed or 0)
    summary.failed = summary.failed + (result.failed or 0)
  end
  return summary
end

return M
