-- Resolve only this native boundary. Do not install a process-wide searcher:
-- LuaLS and browser tooling can load the shared framework in another runtime.
local name = "create.host"
local ok, variants = pcall(require, "moonstone.variants")
if ok then
  local target_ok, target = pcall(require, "moonstone.target")
  if target_ok then
    local file = variants.resolve(name, target)
    if file then return assert(loadfile(file))() end
  end
end
return require(name)
