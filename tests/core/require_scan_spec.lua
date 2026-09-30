local scan = require("hydronium.core.require_scan")

describe("hydronium.core.require_scan", function()
  it("reads call, paren-less and quote-only literal requires, deduplicated in order", function()
    local ids = scan.literal_requires('require("a.b") require \'c\' require"d.e" require("a.b") require ( "f-g" )')
    assert.same(ids, { "a.b", "c", "d.e", "f-g" })
  end)

  it("skips comments, string contents and method calls named require", function()
    local ids = scan.literal_requires(table.concat({
      '-- require("line")',
      '--[==[ require("block") ]==]',
      'local s = "require(\\"in_string\\")"',
      'local t = [[ require("in_long_string") ]]',
      'obj.require("method") obj:require("method2")',
      'require [=[long.arg]=]',
    }, "\n"))
    assert.same(ids, { "long.arg" })
  end)

  it("ignores computed requires (those are the require-discipline lint's job)", function()
    assert.same(scan.literal_requires("require(name) require('x' .. y)"), {})
  end)

  it("walks the closure, skipping ids the loader cannot resolve", function()
    local files = {
      app = 'require("ui.button") require("os")',
      ["ui.button"] = 'require("ui.theme")',
      ["ui.theme"] = "return {}",
    }
    local order, sources = scan.closure({ "app" }, function(id) return files[id] end)
    assert.same(order, { "app", "ui.button", "ui.theme" })
    assert.equal(sources["ui.theme"], "return {}")
  end)

  it("seeds the walk from extra source texts", function()
    local order = scan.closure({}, function(id) return id == "lib" and "return 1" or nil end, { 'require("lib")' })
    assert.same(order, { "lib" })
  end)
end)

describe("hydronium.core.source_topology.scan_roots", function()
  local topology = require("hydronium.core.source_topology")
  it("returns declared roots with nested roots folded into their parent", function()
    assert.same(topology.scan_roots({ roots = {
      { path = "src/views" }, { path = "./src" }, { path = "features/ui" },
    } }), { "features/ui", "src" })
  end)

  it("rejects roots outside the project", function()
    assert.has_error(function() topology.scan_roots({ roots = { { path = "../elsewhere" } } }) end)
  end)
end)
