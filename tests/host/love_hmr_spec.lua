local graph = require("hydronium.core.module_graph")
local hmr = require("hydronium.core.hmr")
local love_hmr = require("hydronium.core.love_hmr")

describe("hydronium.core.love_hmr", function()
  it("commits a safe changed source only from the explicit update boundary", function()
    local id, files = "scratch.love.game", { ["src/game.lua"] = "return { value = 1 }" }
    graph.reset(); package.loaded[id], package.preload[id] = nil, nil
    hmr.install(id, files["src/game.lua"])
    graph.manage(id, { effects = "safe" })
    local adapter = love_hmr.new({
      records = { { id = id, path = "src/game.lua", effects = "safe" } },
      read = function(path) return files[path] end,
    })
    assert.truthy(adapter:prime())
    assert.equal(adapter:update(), nil)
    files["src/game.lua"] = "return { value = 2 }"
    local result = adapter:update()
    assert.equal(result.outcome, "installed")
    assert.equal(require(id).value, 2)
    package.loaded[id], package.preload[id] = nil, nil
    graph.reset()
  end)

  it("does not advance its snapshot across an unsafe or unavailable source", function()
    local id, files = "scratch.love.unsafe", { ["src/unsafe.lua"] = "return { value = 1 }" }
    graph.reset(); package.loaded[id], package.preload[id] = nil, nil
    hmr.install(id, files["src/unsafe.lua"])
    local adapter = love_hmr.new({
      records = { { id = id, path = "src/unsafe.lua", effects = "restart" } },
      read = function(path) return files[path] end,
    })
    assert.truthy(adapter:prime())
    files["src/unsafe.lua"] = "return { value = 2 }"
    assert.equal(adapter:update().outcome, "restart")
    files["src/unsafe.lua"] = nil
    assert.equal(adapter:update().outcome, "restart")
    package.loaded[id], package.preload[id] = nil, nil
    graph.reset()
  end)
end)
