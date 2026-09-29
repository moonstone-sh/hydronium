local path, err = package.searchpath("hydronium_lab.controls", package.path)
if not path then error(err, 0) end
return require("hydronium_luax").loader.load(path:gsub("%.lua$", ".luax"), { module_id = "hydronium_lab.controls" })
