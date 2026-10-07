local client = require("hydronium_ballad.plugins.client")
local graph = require("ballad.graph")

local function fake_ctx()
  return { graph = graph.Graph.new(), fail = function(message) error(message, 0) end, warn = function(_) end }
end

local function ids_of(result)
  local ids = {}
  for _, asset in ipairs(result.assets) do
    if asset.kind == "hy_module" then ids[#ids + 1] = asset.metadata.hydronium.module_id end
  end
  table.sort(ids)
  return ids
end

describe("hydronium_ballad client production bundle entries", function()
  it("walks every stamped client/shared project module, but framework files only when reached", function()
    local store = graph.Graph.new()
    local project = {
      -- Screens are named by string in a router site, never required by App.
      store:add_asset({ kind = "hy_module", virtual_path = "views/App.lua", content = 'return require("lib.used")',
        metadata = { hydronium = { module_id = "views.App", target = "client" } } }),
      store:add_asset({ kind = "hy_module", virtual_path = "views/Home.lua", content = "return 1",
        metadata = { hydronium = { module_id = "views.Home", target = "client" } } }),
      store:add_asset({ kind = "hy_module", virtual_path = "views/Document.lua", content = 'return require("lib.server_only")',
        metadata = { hydronium = { module_id = "views.Document", target = "server" } } }),
    }
    local framework = {
      store:add_asset({ kind = "file", virtual_path = "lib/used.lua", content = "return 2" }),
      store:add_asset({ kind = "file", virtual_path = "lib/unused.lua", content = "return 3" }),
      store:add_asset({ kind = "file", virtual_path = "lib/server_only.lua", content = "return 4" }),
    }
    local result = client.resolve(fake_ctx(), { { assets = project }, { assets = framework } }, { project_entries = true })
    assert.same(ids_of(result), { "lib.used", "views.App", "views.Home" })
  end)

  it("ships stubbed modules as stubs and does not walk their requires", function()
    local store = graph.Graph.new()
    local project = {
      store:add_asset({ kind = "hy_module", virtual_path = "views/App.lua",
        content = 'local barrel = require("pkg")\nreturn barrel',
        metadata = { hydronium = { module_id = "views.App", target = "client" } } }),
    }
    local framework = {
      store:add_asset({ kind = "file", virtual_path = "pkg/init.lua",
        content = 'local t = require("pkg.test")\nreturn { helper = t.helper, real = require("pkg.real") }' }),
      store:add_asset({ kind = "file", virtual_path = "pkg/real.lua", content = "return 1" }),
      store:add_asset({ kind = "file", virtual_path = "pkg/test/init.lua", content = 'return { helper = require("pkg.test.heavy") }' }),
      store:add_asset({ kind = "file", virtual_path = "pkg/test/heavy.lua", content = "return 2" }),
    }
    local result = client.resolve(fake_ctx(), { { assets = project }, { assets = framework } },
      { project_entries = true, stub = { "pkg.test" } })
    assert.same(ids_of(result), { "pkg.init", "pkg.real", "pkg.test.init", "views.App" })
    local stub
    for _, asset in ipairs(result.assets) do
      if asset.kind == "hy_module" and asset.metadata.hydronium.module_id == "pkg.test.init" then stub = asset end
    end
    local load_chunk = loadstring or load
    local chunk, load_err = load_chunk(stub.content)
    if not chunk then error(load_err) end
    local module = chunk()
    local helper = module.helper
    assert.equal(type(helper), "function")
    local ok, err = pcall(helper)
    assert.falsy(ok)
    assert.truthy(tostring(err):find("pkg.test is not part of production browser bundles", 1, true))
    assert.truthy(tostring(err):find("helper", 1, true))
  end)

  it("still requires explicit entries without project_entries", function()
    assert.has_error(function() client.resolve(fake_ctx(), { { assets = {} } }, {}) end)
  end)

  it("luax.compile keeps the topology's declared target instead of its default", function()
    local luax = require("hydronium_ballad.plugins.luax")
    local path = os.tmpname() .. ".luax"
    local f = io.open(path, "w"); f:write('local H = require("hydronium")\nreturn function() return <div>doc</div> end\n'); f:close()
    local store = graph.Graph.new()
    local asset = store:add_asset({ kind = "file", source_path = path, virtual_path = "views/Document.luax",
      metadata = { hydronium = { module_id = "views.Document", target = "server", update = "reload", effects = "restart" } } })
    local ctx = { graph = graph.Graph.new(), fail = function(message) error(message, 0) end, warn = function(_) end }
    local result = luax.compile(ctx, { { assets = { asset } } }, {})
    os.remove(path)
    local h = result.assets[1].metadata.hydronium
    assert.equal(h.module_id, "views.Document")
    assert.equal(h.target, "server")
    assert.equal(h.update, "reload")
  end)
end)
