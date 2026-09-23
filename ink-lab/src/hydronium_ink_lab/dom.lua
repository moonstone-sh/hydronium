-- Lua require entry point for the ambient-DOM LUAX Lab document.
local lua_path, search_error = package.searchpath("hydronium_ink_lab.dom", package.path)
if not lua_path then error(search_error, 0) end
local source_path = lua_path:gsub("%.lua$", ".luax")
return require("hydronium_luax").loader.load(source_path, {
  module_id = "hydronium_ink_lab.dom",
})
