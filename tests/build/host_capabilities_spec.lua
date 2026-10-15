local analysis = require("hydronium_ballad.host_capabilities")
local client = require("hydronium_ballad.plugins.client")
local graph = require("ballad.graph")
local contract = require("hydronium_dom.host.contract").manifest()
local contracts = { contract }
describe("Ballad host capability inventory", function()
  it("reports every use of the removed bridge globals, ignoring strings and comments", function()
    local result, removed = analysis.scan([=[-- _G.__dom_missing
local text = "_G.__dom_missing"
local listener = _G.__dom_set_listener
local direct = __canvas_frame_loop
return _G["__dom_remove_listener"]]=], contracts)
    assert.equal(#result.references, 0); assert.falsy(result.retain_all)
    assert.equal(#removed, 3)
    assert.equal(removed[1].name, "__dom_set_listener"); assert.equal(removed[1].line, 3)
    assert.equal(removed[2].name, "__canvas_frame_loop"); assert.equal(removed[2].line, 4)
    assert.equal(removed[3].name, "__dom_remove_listener"); assert.equal(removed[3].line, 5)
  end)
  it("fails the client bundle on a module that still uses a removed bridge global", function()
    local store = graph.Graph.new()
    local ctx = { graph = store, fail = function(msg) error(msg) end, warn = function() end }
    local asset = store:add_asset({ kind = "hy_module", virtual_path = "App.lua",
      content = "local x = 1\nreturn _G.__dom_set_listener", metadata = { hydronium = { module_id = "App", target = "client" } } })
    local ok, err = pcall(client.resolve, ctx, { { assets = { asset } } }, { entries = { "App" } })
    assert.falsy(ok)
    assert.truthy(tostring(err):find("App:2: __dom_set_listener", 1, true), tostring(err))
    assert.truthy(tostring(err):find("hydronium.runtime.hosts", 1, true), tostring(err))
  end)
  it("records literal versioned host consumers and conservatively retains dynamic calls", function()
    local result = analysis.scan('local hosts = require("hydronium.runtime.hosts")\nreturn hosts.require("dom", 1)', contracts)
    assert.equal(#result.references, 1); assert.falsy(result.retain_all)
    assert.equal(result.references[1].source, "host_registry")
    for _, source in ipairs({ '_G[key]()',
      'local env = _G; return env[key]', 'rawget(_G, key)',
      'local hosts = require("hydronium.runtime.hosts"); return hosts.require(name, 1)',
      'local hosts = require("hydronium.runtime.hosts"); return hosts[method]("dom", 1)',
      'local hosts = require("hydronium.runtime.hosts"); hosts = replacement; return hosts.require("dom", 1)',
      'return require("hydronium.runtime.hosts").require("dom", 1)' }) do
      assert.truthy(analysis.scan(source, contracts).retain_all, source)
    end
  end)
  it("serializes and preserves provider evidence through resolution, minification and bundling", function()
    local store = graph.Graph.new()
    local ctx = { graph = store, fail = function(msg) error(msg) end, warn = function() end }
    local asset = store:add_asset({ kind = "hy_module", virtual_path = "App.lua",
      content = 'local hosts = require("hydronium.runtime.hosts")\nreturn hosts.require("dom", 1)', metadata = { hydronium = { module_id = "App", target = "client" } } })
    local resolved = client.resolve(ctx, { { assets = { asset } } }, { entries = { "App" } })
    local report
    for _, a in ipairs(resolved.assets) do if a.kind == "hy_module_graph" then
      report = require("dkjson").decode(a.content).host_capabilities
    end end
    assert.equal(report.schema, "hydronium.host-capabilities.v1")
    assert.equal(report.providers[1].provider.export, "createDomBridge")
    assert.equal(report.elimination, "disabled")
    local minified = client.minify(ctx, { resolved }, { level = "safe" })
    local bundled = client.bundle(ctx, { minified }, { name = "host-test" })
    assert.equal(bundled.assets[1].metadata.hydronium.host_capabilities[1].providers[1].name, "dom")
  end)
end)
