-- Compatibility transport only. New consumers resolve the VM-local registry.
local contract = require("hydronium_dom.host.contract")
local M = {}
function M.read(environment)
  local bridge = {}
  for _, method in ipairs(contract.manifest().methods) do
    bridge[method.name] = environment[method.legacy_global]
  end
  return bridge
end
return M
