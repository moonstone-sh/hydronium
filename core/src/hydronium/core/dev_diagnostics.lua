-- Optional source-location descriptions for development sessions.
-- Import/install this from a dev entrypoint, never from the rendering core.
local diagnostics = require("hydronium.compat.diagnostics")
local dev = require("hydronium.core.dev")
local M = {}

function M.describe(component)
  local source, line = diagnostics.function_location(component.type)
  if source then
    return "the component defined at " .. source:gsub("^.*[/\\]", "") .. ":" .. line
  end
  return nil
end

--- Enable rich warning descriptions; return an owner-scoped release function.
function M.install()
  return dev.install_describer(M.describe)
end

return M
