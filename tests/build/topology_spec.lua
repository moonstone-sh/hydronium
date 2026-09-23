local topology = require("hydronium_ballad.plugins.topology")
local graph = require("ballad.graph")

local function fake_ctx()
  return {
    graph = graph.Graph.new(),
    fail = function(_, message) error(message, 0) end,
  }
end

describe("hydronium_ballad.plugins.topology", function()
  it("stamps Ballad assets from the project declaration without mutating inputs", function()
    local assets = graph.Graph.new()
    local app = assets:add_asset({ kind = "file", source_path = "/project/src/App.luax", virtual_path = "src/App.luax" })
    local card = assets:add_asset({ kind = "file", source_path = "/project/src/features/Card.lua", virtual_path = "src/features/Card.lua" })
    local result = topology.classify(fake_ctx(), { { assets = { app, card } } }, {
      root = "/project",
      config = {
        roots = { { path = "src", namespace = "app", target = "client" } },
        entries = { { id = "app", path = "src/App.luax" } },
      },
    })
    assert.equal(#result.assets, 2)
    assert.equal(result.assets[1].metadata.hydronium.module_id, "app")
    assert.equal(result.assets[2].metadata.hydronium.module_id, "app.features.Card")
    assert.equal(result.assets[2].metadata.hydronium.effects, "restart")
    assert.equal(app.metadata.hydronium, nil)
  end)

  it("excludes assets outside the declared source roots", function()
    local assets = graph.Graph.new()
    local app = assets:add_asset({ kind = "file", source_path = "/project/src/App.lua", virtual_path = "src/App.lua" })
    local public = assets:add_asset({ kind = "file", source_path = "/project/public/main.js", virtual_path = "public/main.js" })
    local result = topology.classify(fake_ctx(), { { assets = { app, public } } }, {
      root = "/project", config = { roots = { { path = "src" } } },
    })
    assert.equal(#result.assets, 1)
    assert.equal(result.assets[1].metadata.hydronium.module_id, "App")
  end)

  it("emits a private revisioned inventory with the normalized physical mapping", function()
    local assets = graph.Graph.new()
    local app = assets:add_asset({ kind = "file", source_path = "/project/src/App.luax", virtual_path = "src/App.luax" })
    local inventory = topology.inventory(fake_ctx(), { { assets = { app } } }, {
      root = "/project",
      config = { roots = { { path = "src", namespace = "app", effects = "safe" } } },
    })
    assert.equal(#inventory.assets, 2)
    local output = inventory.assets[1]
    assert.equal(output.virtual_path, ".hydronium/source-inventory.json")
    assert.truthy(output.content:find('"path":"src/App.luax"', 1, true))
    assert.truthy(output.content:find('"effects":"safe"', 1, true))
    assert.truthy(output.metadata.hydronium.private)
    assert.truthy(output.metadata.hydronium.revision:find("b3:", 1, true))
    assert.equal(inventory.assets[2].virtual_path, ".hydronium/source-inventory.lua")
  end)
end)
