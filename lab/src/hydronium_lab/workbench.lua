-- Lua's stock module search does not discover `.luax` files. Keep a tiny
-- conventional shim so hosts can require the shared workbench normally.
local lua_path, search_error = package.searchpath("hydronium_lab.workbench", package.path)
if not lua_path then error(search_error, 0) end
local source_path = lua_path:gsub("%.lua$", ".luax")
return require("hydronium_luax").loader.load(source_path, {
  module_id = "hydronium_lab.workbench",
})
