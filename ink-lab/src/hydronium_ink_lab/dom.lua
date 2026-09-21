-- Lua require entry point for the ambient-DOM LUAX Lab document.
local lua_path = assert(package.searchpath("hydronium_ink_lab.dom", package.path))
local source_path = assert(lua_path:gsub("%.lua$", ".luax"))
return require("hydronium_luax").loader.load(source_path, {
  module_id = "hydronium_ink_lab.dom",
})
