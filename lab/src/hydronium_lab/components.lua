-- Conventional require entry point for the LUAX component library.
local path, err = package.searchpath("hydronium_lab.components", package.path)
if not path then error(err, 0) end
return require("hydronium_luax").loader.load(path:gsub("%.lua$", ".luax"), { module_id="hydronium_lab.components" })
