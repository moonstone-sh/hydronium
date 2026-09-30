local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
package.path = "./luax/src/?.lua;./dom/src/?.lua;" .. package.path

describe("Markdown app dev modules", function()
  it("serves a declared MDX module as compiled Lua for initial load and HMR", function()
    local routes = require("hydronium_dom.server.meteorite_routes")
    local registry = require("hydronium_dom.dev.source_registry").from_config({
      roots = { { path = "tests/fixtures/lab_mixed", transforms = { mdx = "mdx" } } },
      files = { "tests/fixtures/lab_mixed/Docs.mdx" },
    })
    local previous = routes.registry
    routes.registry = function() return registry end
    local context = {
      param = function(_, name) if name == "id" then return "Docs" end end,
      query = function() return nil end,
      text = function(_, status, body) return { status = status, body = body } end,
    }
    local ok, response = pcall(require("hydronium_dom.server.meteorite_routes.dev_module"), context)
    routes.registry = previous
    assert.truthy(ok, response)
    assert.equal(response.status, 200)
    assert.truthy(response.body:find('H.h%(HydroniumMdH1'))
    assert.truthy(response.body:find('require%("DocsBadge"%)'))
  end)
end)
