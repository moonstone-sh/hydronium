local describe = _G.describe
local it = _G.it
local assert = _G.assert

local client_manifest = require("hydronium_dom.dev.client_manifest")

describe("hydronium_dom.dev.client_manifest", function()
  it("covers every module the browser runtime JS requires, with /hydronium-src paths", function()
    local manifest = client_manifest.build()
    assert.equal(manifest["hydronium.core.module_graph"], "hydronium/core/module_graph.lua")
    assert.equal(manifest["hydronium_dom"], "hydronium_dom/init.lua")
    assert.truthy(manifest["hydronium.core.reconciler"])
    assert.truthy(manifest["hydronium_router.history.browser"])
  end)

  it("follows the project's own requires into the framework, but never emits project modules", function()
    local manifest = client_manifest.build(nil, {
      'local r = require("hydronium_router")\nlocal views = require("views.Home")\nlocal os_ = require("os")',
    })
    assert.truthy(manifest["hydronium_router"])
    assert.truthy(manifest["hydronium_router.matcher"])
    assert.is_nil(manifest["views.Home"])
    assert.is_nil(manifest["os"])
  end)


end)
