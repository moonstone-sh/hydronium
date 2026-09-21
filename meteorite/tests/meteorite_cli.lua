-- End-to-end fixture wrapper: the project runtime executes the Meteorite CLI,
-- while Meteorite's own tool environment supplies its CLI-only dependencies.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local hydronium_root = assert(source:match("^(.*)/hydronium/meteorite/tests/meteorite_cli%.lua$"))
local meteorite_root = hydronium_root .. "/meteorite"
package.path = table.concat({
  meteorite_root .. "/src/?.lua", meteorite_root .. "/src/?/init.lua",
  meteorite_root .. "/.moonstone/env/share/lua/5.4/?.lua",
  meteorite_root .. "/.moonstone/env/share/lua/5.4/?/init.lua",
  package.path,
}, ";")
dofile(meteorite_root .. "/src/cli/main.lua")
