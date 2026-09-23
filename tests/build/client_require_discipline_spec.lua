local client = require("hydronium_ballad.plugins.client")
local graph = require("ballad.graph")

local function fake_ctx()
  return {
    graph = graph.Graph.new(),
    -- client.lua calls both ctx.fail(msg) and ctx.warn(msg) as plain
    -- dot-calls with a single string argument -- match that convention
    -- exactly rather than topology_spec's colon-call fake_ctx shape.
    fail = function(message) error(message, 0) end,
    warn = function(_) end,
  }
end

--- Builds one `hy_module` asset (registered on a real Graph, matching
--- tests/build/topology_spec.lua's own fixture pattern) and returns its
--- handle so the caller can collect it into an `{ assets = {...} }` input
--- set -- client.resolve() never reads a Graph's own asset list directly.
local function make_module(store, module_id, content, target)
  return store:add_asset({
    kind = "hy_module",
    virtual_path = module_id:gsub("%.", "/") .. ".lua",
    content = content,
    metadata = { hydronium = { module_id = module_id, target = target or "client" } },
  })
end

local function resolved_module_ids(result)
  local ids = {}
  for _, asset in ipairs(result.assets) do
    if asset.kind == "hy_module" then
      table.insert(ids, asset.metadata.hydronium.module_id)
    end
  end
  table.sort(ids)
  return ids
end

describe("hydronium_ballad.plugins.client require discipline", function()
  it("bundles a module graph where every require() is a static literal", function()
    local store = graph.Graph.new()
    local mods = {
      make_module(store, "App", 'local Helper = require("Helper")\nreturn Helper'),
      make_module(store, "Helper", 'return { greet = function() return "hi" end }'),
    }
    local result = client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "App" } })
    local ids = resolved_module_ids(result)
    assert.equal(#ids, 2)
    assert.equal(ids[1], "App")
    assert.equal(ids[2], "Helper")
  end)

  it("does not flag require \"literal\" sugar or a field named require on another table", function()
    local store = graph.Graph.new()
    local mods = {
      make_module(store, "App", 'local Helper = require "Helper"\nlocal x = some_table.require\nreturn Helper'),
      make_module(store, "Helper", "return {}"),
    }
    local result = client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "App" } })
    assert.equal(#resolved_module_ids(result), 2)
  end)

  it("fails the build when a reachable module calls require() with a non-literal argument", function()
    local store = graph.Graph.new()
    local mods = { make_module(store, "App", 'local id = "Helper"\nrequire(id)\nreturn {}') }
    assert.has_error(function()
      client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "App" } })
    end, "non-literal argument")
  end)

  it("fails the build when a reachable module reassigns _G.require", function()
    local store = graph.Graph.new()
    local mods = { make_module(store, "App", "_G.require = function(id) return nil end\nreturn {}") }
    assert.has_error(function()
      client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "App" } })
    end, "_G.require is reassigned")
  end)

  it("fails the build when a reachable module reassigns bare require with no local keyword", function()
    local store = graph.Graph.new()
    local mods = { make_module(store, "App", "require = function(id) return nil end\nreturn {}") }
    assert.has_error(function()
      client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "App" } })
    end, "rebinds the GLOBAL")
  end)

  it("does not flag a local variable named require shadowing the global", function()
    local store = graph.Graph.new()
    local mods = {
      make_module(store, "App", 'local require = function(id) return nil end\nreturn require("Helper")'),
      make_module(store, "Helper", "return {}"),
    }
    local result = client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "App" } })
    assert.equal(#resolved_module_ids(result), 2)
  end)

  it("fails the build when a reachable module writes package.loaded[...] directly", function()
    local store = graph.Graph.new()
    local mods = { make_module(store, "App", "package.loaded[some_id] = nil\nreturn {}") }
    assert.has_error(function()
      client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "App" } })
    end, "package.loaded%[...%] is assigned")
  end)

  it("fails the build when a reachable module writes package.preload[...] directly", function()
    local store = graph.Graph.new()
    local mods = { make_module(store, "App", "package.preload[some_id] = function() end\nreturn {}") }
    assert.has_error(function()
      client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "App" } })
    end, "package.preload%[...%] is assigned")
  end)

  it("does not flag the same patterns inside an allowlisted framework module", function()
    local store = graph.Graph.new()
    local mods = {
      make_module(store, "hydronium.core.module_graph", "_G.require = function(id) return nil end\nreturn {}"),
    }
    local result = client.resolve(fake_ctx(), { { assets = mods } }, { entries = { "hydronium.core.module_graph" } })
    assert.equal(#resolved_module_ids(result), 1)
  end)

  it("accepts an extra allowlist entry via opts.require_discipline_allowlist", function()
    local store = graph.Graph.new()
    local mods = {
      make_module(store, "app.plugins.custom_loader", "_G.require = function(id) return nil end\nreturn {}"),
    }
    local result = client.resolve(fake_ctx(), { { assets = mods } }, {
      entries = { "app.plugins.custom_loader" },
      require_discipline_allowlist = { "app.plugins.custom_loader" },
    })
    assert.equal(#resolved_module_ids(result), 1)
  end)

  it("can be disabled entirely via opts.enforce_require_discipline = false", function()
    local store = graph.Graph.new()
    local mods = { make_module(store, "App", "_G.require = function(id) return nil end\nreturn {}") }
    local result = client.resolve(fake_ctx(), { { assets = mods } },
      { entries = { "App" }, enforce_require_discipline = false })
    assert.equal(#resolved_module_ids(result), 1)
  end)
end)
