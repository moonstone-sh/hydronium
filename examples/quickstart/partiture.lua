-- Ballad source discovery: .hydronium/ballad/source-inventory.lua, the module
-- authority the dev host serves from. dev.sh runs it before the server starts.
local ballad = require("ballad")
local hb = require("hydronium_ballad")

return ballad.partiture(function(p)
  hb.source_inventory(p)
end)
