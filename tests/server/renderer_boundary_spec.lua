local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local h = require("hydronium.core.element").h
local renderer = require("hydronium_dom.server.renderer")
local server = require("hydronium_dom.server")
local d = require("hydronium_dom").d
local vite = require("hydronium_dom.server.vite_module")

local function island()
  return h(d.js.island, {module="src/island.js"}, h("p", {}, "fallback"))
end

describe("plain SSR renderer integration boundary", function()
  it("imports no Meteorite, Vite, or filesystem asset integration", function()
    local original = require
    local blocked = {
      ["hydronium_dom.server"]=true,
      ["hydronium_dom.server.meteorite"]=true,
      ["hydronium_dom.server.vite_module"]=true,
      ["hydronium_dom.assets"]=true,
    }
    require = function(id)
      if blocked[id] then error("plain renderer imported " .. id) end
      return original(id)
    end
    local ok, value = pcall(function()
      return loadfile("dom/src/hydronium_dom/server/renderer.lua")()
    end)
    require = original
    assert.truthy(ok, tostring(value))
    assert.equal(value.render_to_string(h("p", {}, "plain")), "<p>plain</p>")
  end)

  it("passes through JS URLs independently of the site's Vite configuration", function()
    vite.configure({mode="dev",vite_origin="http://localhost:5173"})
    local _, plain = renderer.render_to_string(island())
    local _, integrated = server.render_to_string(island())
    vite.reset()
    assert.equal(plain.islands[1].module, "src/island.js")
    assert.equal(integrated.islands[1].module, "http://localhost:5173/src/island.js")
  end)

  it("scopes an explicit resolver to one render and leaves options untouched", function()
    local calls = 0
    local options = {module_resolver=function(specifier) calls=calls+1;return "/built/"..specifier end}
    local _, plan = renderer.render_to_string(island(), options)
    local _, next_plan = renderer.render_to_string(island())
    assert.equal(plan.islands[1].module, "/built/src/island.js")
    assert.equal(next_plan.islands[1].module, "src/island.js")
    assert.equal(calls, 1)
    assert.equal(options.suppress_client_plan_script, nil)
    local lua_island = h(d.lua.island, {module="views.App"}, h("p", {}, "Lua"))
    renderer.render_to_string(lua_island, options)
    assert.equal(calls, 1, "Lua module IDs must never reach the JS resolver")
    local ok, err = pcall(renderer.render_to_string, island(), {module_resolver=true})
    assert.falsy(ok)
    assert.truthy(tostring(err):find("module_resolver must be a function",1,true))
  end)

  it("preserves page-wide island IDs through the integrated entrypoint", function()
    vite.configure({mode="dev",vite_origin="http://localhost:5173"})
    local options = {}
    local _, plan = server.render_page(function(render)
      return render(island(), options)..render(island())
    end)
    vite.reset()
    assert.equal(#plan.islands, 2)
    assert.equal(plan.islands[1].id, "hy:i1")
    assert.equal(plan.islands[2].id, "hy:i2")
    assert.equal(plan.islands[2].module, "http://localhost:5173/src/island.js")
    assert.equal(options.module_resolver, nil)
  end)
end)
