local analysis = require("hydronium_ballad.host_capabilities")
local client = require("hydronium_ballad.plugins.client")
local graph = require("ballad.graph")
local contract = require("hydronium_dom.host.contract").manifest()
local contracts = { contract }
describe("Ballad host capability inventory", function()
  it("joins legacy literal reads to providers and effects, ignoring strings and comments", function()
    local result = analysis.scan([=[-- _G.__dom_missing
local text = "_G.__dom_missing"
local listener = _G.__dom_set_listener
return _G["__dom_remove_listener"]]=], contracts)
    assert.equal(#result.references, 2); assert.falsy(result.retain_all)
    assert.equal(result.references[1].method, "set_listener")
    assert.equal(result.references[1].effect, "dom.listen")
    assert.equal(result.references[1].line, 3)
  end)
  it("records literal versioned host consumers and conservatively retains dynamic calls", function()
    local result = analysis.scan('local hosts = require("hydronium.runtime.hosts")\nreturn hosts.require("dom", 1)', contracts)
    assert.equal(#result.references, 1); assert.falsy(result.retain_all)
    assert.equal(result.references[1].source, "host_registry")
    for _, source in ipairs({ '_G[key]()', '_G.__dom_set_listener = replacement',
      'local env = _G; return env[key]', 'rawget(_G, key)',
      'local hosts = require("hydronium.runtime.hosts"); return hosts.require(name, 1)',
      'local hosts = require("hydronium.runtime.hosts"); return hosts[method]("dom", 1)',
      'local hosts = require("hydronium.runtime.hosts"); hosts = replacement; return hosts.require("dom", 1)' }) do
      assert.truthy(analysis.scan(source, contracts).retain_all, source)
    end
  end)
  it("serializes and preserves provider evidence through resolution, minification and bundling", function()
    local store = graph.Graph.new()
    local ctx = { graph = store, fail = function(msg) error(msg) end, warn = function() end }
    local asset = store:add_asset({ kind = "hy_module", virtual_path = "App.lua",
      content = "return _G.__dom_set_listener", metadata = { hydronium = { module_id = "App", target = "client" } } })
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
