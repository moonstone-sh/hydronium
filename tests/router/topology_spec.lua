local topology = require("hydronium_router.topology")

describe("hydronium_router.topology", function()
  it("lowers explicit route tags without assigning semantics to paths", function()
    local routes = topology.routes({
      { id = "app.features.Post", path = "src/features/Post.luax", target = "client",
        tags = { route = { id = "post", path = "/posts/:id", meta = { cache = "public" } } } },
      { id = "app.layers.Frame", path = "src/layers/Frame.luax", target = "client", tags = {} },
      { id = "app.api.Health", path = "src/anything/Health.lua", target = "server",
        tags = { route = { path = "/health" } } },
    })
    assert.equal(#routes, 2)
    assert.equal(routes[1].id, "app.api.Health")
    assert.equal(routes[1].module, "app.api.Health")
    assert.equal(routes[2].path, "/posts/:id")
    assert.equal(routes[2].meta.cache, "public")
  end)

  it("rejects malformed or ambiguous tag declarations", function()
    assert.falsy(pcall(topology.routes, { { id = "a", target = "client", tags = { route = "routes/a" } } }))
    assert.falsy(pcall(topology.routes, {
      { id = "a", target = "client", tags = { route = { path = "/same" } } },
      { id = "b", target = "client", tags = { route = { path = "/same" } } },
    }))
  end)
end)
