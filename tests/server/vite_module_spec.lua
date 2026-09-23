-- Tests for hydronium_dom.server.vite_module (M2 of
-- docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md: hy_asset_ref resolution for
-- `d.js.island` module specifiers) and its wiring into
-- hydronium_dom.server.init's ISLAND rendering.

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local vite_module = require("hydronium_dom.server.vite_module")
local assets = require("hydronium_dom.assets")
local server = require("hydronium_dom.server")
local H = require("hydronium")
local dom = require("hydronium_dom")
local d = dom.d

describe("hydronium_dom.server.vite_module -- hy_asset_ref", function()
  it("hy_asset_ref(specifier) carries asset_id and specifier per Contract 3", function()
    local ref = vite_module.hy_asset_ref("./counter-island.js")
    assert.equal(ref.kind, "hy_asset_ref")
    assert.equal(ref.specifier, "./counter-island.js")
    -- asset_id == specifier today: no luax.compile-time id assignment
    -- exists yet for JS island specifiers (see this module's own header).
    assert.equal(ref.asset_id, "./counter-island.js")
  end)

  it("hy_asset_ref requires a string specifier", function()
    assert.falsy(pcall(vite_module.hy_asset_ref, nil))
    assert.falsy(pcall(vite_module.hy_asset_ref, 42))
  end)
end)

describe("hydronium_dom.server.vite_module -- resolve() unconfigured (default)", function()
  it("is not configured by default", function()
    vite_module.reset()
    assert.falsy(vite_module.is_configured())
    assert.equal(vite_module.mode(), nil)
  end)

  it("passes a bare string specifier through byte-for-byte", function()
    vite_module.reset()
    assert.equal(vite_module.resolve("/js/island/counter.js"), "/js/island/counter.js")
    assert.equal(vite_module.resolve("./chart.js"), "./chart.js")
  end)

  it("passes a hy_asset_ref table's specifier through unchanged", function()
    vite_module.reset()
    local ref = vite_module.hy_asset_ref("./chart.js")
    assert.equal(vite_module.resolve(ref), "./chart.js")
  end)

  it("passes non-string values through untouched (e.g. nil for a lua mount with no module)", function()
    vite_module.reset()
    assert.equal(vite_module.resolve(nil), nil)
  end)
end)

describe("hydronium_dom.server.vite_module -- resolve() dev mode", function()
  it("prefixes a specifier with the configured Vite origin", function()
    vite_module.configure({ mode = "dev", vite_origin = "http://localhost:5173" })
    assert.truthy(vite_module.is_configured())
    assert.equal(vite_module.mode(), "dev")
    assert.equal(vite_module.resolve("src/counter-island.js"), "http://localhost:5173/src/counter-island.js")
    vite_module.reset()
  end)

  it("adds a leading slash to a specifier that lacks one", function()
    vite_module.configure({ mode = "dev", vite_origin = "http://localhost:5173" })
    assert.equal(vite_module.resolve("counter-island.js"), "http://localhost:5173/counter-island.js")
    vite_module.reset()
  end)

  it("does not double a leading slash already present on the specifier", function()
    vite_module.configure({ mode = "dev", vite_origin = "http://localhost:5173" })
    assert.equal(vite_module.resolve("/src/counter-island.js"), "http://localhost:5173/src/counter-island.js")
    vite_module.reset()
  end)

  it("trims a trailing slash on the configured origin", function()
    vite_module.configure({ mode = "dev", vite_origin = "http://localhost:5173/" })
    assert.equal(vite_module.resolve("/src/x.js"), "http://localhost:5173/src/x.js")
    vite_module.reset()
  end)

  it("requires a string vite_origin for dev mode", function()
    assert.falsy(pcall(vite_module.configure, { mode = "dev" }))
    vite_module.reset()
  end)
end)

describe("hydronium_dom.server.vite_module -- resolve() prod mode delegates to hydronium_dom.assets", function()
  -- Prod mode needs no config of its own (see vite_module.lua's own
  -- header on why): it forwards to hydronium_dom.assets.url(specifier),
  -- the SAME mechanism M3's vite_assets ballad plugin feeds via the
  -- ordinary hydronium-manifest.lua merge. These tests exercise that
  -- real delegation against hydronium_dom.assets' own real
  -- configure()/reset(), not a mock.

  local function write_temp_manifest(lua_source)
    local path = os.tmpname() .. ".lua"
    local f = io.open(path, "w")
    assert.truthy(f)
    f:write(lua_source)
    f:close()
    return path
  end

  it("looks up the specifier via a real hydronium-manifest.lua and returns its hashed URL", function()
    local path = write_temp_manifest([[
return {
  version = 1,
  assets = {
    ["src/counter-island.js"] = { url = "/assets/counter-island-abc123.js", integrity = "b3:abc123" },
  },
  styles = {},
}
]])
    assets.configure(path)
    vite_module.configure({ mode = "prod" })
    assert.equal(vite_module.resolve("src/counter-island.js"), "/assets/counter-island-abc123.js")
    vite_module.reset()
    assets.reset()
    os.remove(path)
  end)

  it("falls back to the raw '/'..specifier when assets was never configured -- same dev-fallback "
    .. "policy as every other asset URL in this codebase, not a Vite-specific exception", function()
    assets.reset()
    vite_module.configure({ mode = "prod" })
    assert.equal(vite_module.resolve("src/missing.js"), "/src/missing.js")
    vite_module.reset()
  end)

  it("falls back to the raw '/'..specifier when assets IS configured but has no matching entry", function()
    local path = write_temp_manifest([[return { version = 1, assets = {}, styles = {} }]])
    assets.configure(path)
    vite_module.configure({ mode = "prod" })
    assert.equal(vite_module.resolve("src/unknown.js"), "/src/unknown.js")
    vite_module.reset()
    assets.reset()
    os.remove(path)
  end)
end)

describe("hydronium_dom.server.vite_module wired into hydronium_dom.server.init's ISLAND rendering", function()
  it("leaves a Lua island's module (a require() id, not a JS specifier) completely untouched, even when Vite dev mode is configured", function()
    vite_module.configure({ mode = "dev", vite_origin = "http://localhost:5173" })
    local mounted = d.lua.mount(H.h("div", nil, "x"), { module = "app.client.root" })
    local _, plan = server.render_to_string(mounted)
    assert.equal(plan.islands[1].module, "app.client.root")
    vite_module.reset()
  end)

  it("resolves a JS island's module through the configured dev origin", function()
    vite_module.configure({ mode = "dev", vite_origin = "http://localhost:5173" })
    local vnode = H.h(d.js.island, { module = "src/counter-island.js" }, H.h("button", nil, "hi"))
    local _, plan = server.render_to_string(vnode)
    assert.equal(plan.islands[1].interpreter, "js")
    assert.equal(plan.islands[1].module, "http://localhost:5173/src/counter-island.js")
    vite_module.reset()
  end)

  it("resolves a JS island's module through the real hydronium_dom.assets manifest (M3's eventual join point)", function()
    local path = os.tmpname() .. ".lua"
    local f = io.open(path, "w")
    assert.truthy(f)
    f:write([[
return {
  version = 1,
  assets = { ["src/counter-island.js"] = { url = "/assets/counter-island-abc123.js" } },
  styles = {},
}
]])
    f:close()
    assets.configure(path)
    vite_module.configure({ mode = "prod" })

    local vnode = H.h(d.js.island, { module = "src/counter-island.js" }, H.h("button", nil, "hi"))
    local _, plan = server.render_to_string(vnode)
    assert.equal(plan.islands[1].module, "/assets/counter-island-abc123.js")

    vite_module.reset()
    assets.reset()
    os.remove(path)
  end)

  it("REGRESSION: leaves a JS island's module untouched when Vite is not configured -- the "
    .. "existing 'assigns distinct... IDs' spec in islands_suspense_spec.lua asserts "
    .. "module == './chart.js' verbatim, and this must stay true", function()
    vite_module.reset()
    local vnode = H.h(d.js.island, { module = "./chart.js" }, H.h("span", nil, "b"))
    local _, plan = server.render_to_string(vnode)
    assert.equal(plan.islands[1].module, "./chart.js")
  end)
end)
