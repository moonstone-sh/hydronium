-- Compiles the stable document shell on demand. It lives in a requirable
-- module because Meteorite lifts inline hybrid handlers and they cannot close
-- over a module local declared in src/main.lua.
local loader = require("hydronium_luax").loader

return loader.load("views/Document.luax")
