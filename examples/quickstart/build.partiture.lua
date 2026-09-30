-- `moon run build` runs this before compiling the server: the source
-- inventory, then one content-hashed browser chunk with every client/shared
-- module declared in hydronium.sources.lua plus only the framework modules
-- they reach (.hydronium/client/). Release pages boot from that chunk.
local ballad = require("ballad")
local hb = require("hydronium_ballad")

return ballad.partiture(function(p)
  hb.source_inventory(p)
  hb.client_bundle(p)
end)
