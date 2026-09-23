local registry = require("hydronium_dom.dev.source_registry")

describe("hydronium_dom.dev.source_registry", function()
  it("whitelists normalized module IDs and emits public browser metadata", function()
    local source = registry.from_config({
      entry = "app",
      files = { "ui/App.luax", "ui/features/Counter.luax", "server/admin.lua" },
      roots = {
        { path = "ui", namespace = "app", target = "client", update = "hot" },
        { path = "server", namespace = "server", target = "server", update = "restart" },
      },
      entries = { { id = "app", path = "ui/App.luax" } },
    })
    assert.equal(source:module("app.features.Counter").path, "ui/features/Counter.luax")
    assert.equal(source:module("server.admin").target, "server")
    assert.equal(source:module("missing"), nil)
    local manifest = source:browser_manifest()
    assert.equal(manifest.entry, "app")
    assert.equal(manifest.modules.app.url, "/__hydronium/dev/module/app")
    assert.equal(manifest.modules["server.admin"], nil)
    assert.equal(manifest.updates["server/admin.lua"].action, "restart")
    assert.same(source:watch_files({ "public/site.css", "ui/App.luax" }), {
      "public/site.css", "server/admin.lua", "ui/App.luax", "ui/features/Counter.luax",
    })
  end)

  it("requires an explicit inventory rather than scanning from a request", function()
    assert.falsy(pcall(registry.from_config, { roots = { { path = "src" } } }))
  end)

  it("treats a loaded topology declaration as a reload boundary", function()
    local source = registry.load("tests/fixtures/source_topology.lua")
    assert.equal(source:browser_manifest().updates["tests/fixtures/source_topology.lua"].action, "reload")
    assert.truthy(table.concat(source:watch_files(), "|"):find("tests/fixtures/source_topology.lua", 1, true))
  end)

  it("uses a generated inventory without rediscovering filesystem paths", function()
    local source = registry.from_inventory({
      version = 1, revision = "b3:inventory", config = {
        entry = "app", roots = { { path = "src", namespace = "app", effects = "safe" } },
        entries = { { id = "app", path = "src/App.lua" } },
      },
      records = { { id = "app", path = "src/App.lua", transform = "lua", target = "client", update = "hot", effects = "safe" } },
    })
    assert.equal(source:module("app").path, "src/App.lua")
    assert.equal(source:browser_manifest().revision, "b3:inventory")
  end)

  it("rejects an inventory whose records do not match its embedded declaration", function()
    assert.falsy(pcall(registry.from_inventory, {
      version = 1, config = { roots = { { path = "src", namespace = "app" } } },
      records = { { id = "wrong", path = "src/App.lua", transform = "lua", target = "client", update = "hot", effects = "restart" } },
    }))
  end)
end)
