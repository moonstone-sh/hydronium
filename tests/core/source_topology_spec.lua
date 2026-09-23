local topology = require("hydronium.core.source_topology")
local inventory = require("hydronium.core.source_inventory")

describe("hydronium.core.source_topology", function()
  it("maps arbitrary roots mechanically and supports an explicit entry", function()
    local records = topology.resolve({
      roots = {
        { path = "src", namespace = "app", effects = "safe", transforms = { lua = "lua", luax = "luax" } },
        { path = "shared", namespace = "shared", target = "shared", update = "remount" },
      },
      entries = { { id = "app", path = "src/App.luax" } },
    }, { "src/App.luax", "src/features/auth/Login.luax", "shared/date.lua", "README.md" })
    assert.equal(records[1].id, "app")
    assert.equal(records[2].id, "app.features.auth.Login")
    assert.equal(records[3].id, "shared.date")
    assert.equal(records[3].target, "shared")
    assert.equal(records[3].update, "remount")
    assert.equal(records[1].effects, "safe")
    assert.equal(records[3].effects, "restart", "undeclared effects must fail closed at runtime")
  end)

  it("rejects unknown effect declarations", function()
    assert.falsy(pcall(topology.resolve, {
      roots = { { path = "src", effects = "arbitrary" } },
    }, { "src/App.lua" }))
  end)

  it("rejects colliding logical module identities", function()
    local ok, err = pcall(topology.resolve, {
      roots = { { path = "src", namespace = "app" } },
      entries = { { id = "app.same", path = "src/a.lua" }, { id = "app.same", path = "src/b.lua" } },
    }, { "src/a.lua", "src/b.lua" })
    assert.falsy(ok)
    assert.truthy(tostring(err):find("collision", 1, true))
  end)

  it("rejects traversal in declarations and discovered paths", function()
    assert.falsy(pcall(topology.resolve, { roots = { { path = "../src" } } }, {}))
    assert.falsy(pcall(topology.resolve, { roots = { { path = "src" } } }, { "src/../secret.lua" }))
  end)

  it("rejects overlapping roots and case-folding collisions", function()
    assert.falsy(pcall(topology.resolve, {
      roots = { { path = "src" }, { path = "src/features" } },
    }, { "src/features/Card.lua" }))
    assert.falsy(pcall(topology.resolve, {
      roots = { { path = "src" } },
    }, { "src/Card.lua", "src/card.lua" }))
  end)

  it("validates a generated inventory before a host consumes its records", function()
    local resolved = inventory.from_table({
      version = 1, revision = "b3:test",
      config = { roots = { { path = "src", namespace = "app", effects = "safe" } },
        entries = { { id = "app", path = "src/App.lua" } } },
      records = { { id = "app", path = "src/App.lua", transform = "lua", target = "client", update = "hot", effects = "safe" } },
    })
    assert.equal(resolved.revision, "b3:test")
    assert.equal(resolved.records[1].id, "app")
    assert.falsy(pcall(inventory.from_table, {
      version = 1, config = { roots = { { path = "src" } } },
      records = { { id = "wrong", path = "src/App.lua" } },
    }))
  end)
end)
