local graph = require("ballad.graph")
local site = require("hydronium_ballad.plugins.site")

local function ctx()
  return { graph = graph.Graph.new() }
end

describe("hydronium_ballad.plugins.site manifest", function()
  it("publishes client module semantics without source origins", function()
    local assets = graph.Graph.new()
    local module = assets:add_asset({
      kind = "hy_module", generated = true, virtual_path = "app.lua", content = "return {}",
      metadata = { hydronium = {
        module_id = "app", origin = "/private/project/src/App.luax", target = "client",
        transform = "luax", update = "hot", revision = "b3-test",
        effects = "safe",
      } },
    })
    local result = site.manifest(ctx(), { { assets = { module } } }, { name = "manifest" })
    local json
    for _, asset in ipairs(result.assets) do
      if asset.virtual_path == "manifest.json" then json = asset.content end
    end
    assert.truthy(json)
    assert.truthy(json:find('"app"', 1, true))
    assert.truthy(json:find('"hot"', 1, true))
    assert.truthy(json:find('"safe"', 1, true))
    assert.falsy(json:find("/private/project", 1, true))
  end)
end)
