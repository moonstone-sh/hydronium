--[[
  hydronium_dom.assets -- the runtime half of static-asset resolution.
  The build-time half (hydronium_ballad.plugins.assets.hash) lives
  outside this native suite (it's a ballad-graph plugin); this file
  covers configure()/url()/reset() against a REAL manifest file on disk,
  written by this test itself in exactly the shape the real plugin
  emits (see docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 3).
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local assets = require("hydronium_dom.assets")

local function write_temp_manifest(lua_source)
  local path = os.tmpname() .. ".lua"
  local f = io.open(path, "w")
  f:write(lua_source)
  f:close()
  return path
end

describe("hydronium_dom.assets -- static asset URL resolution", function()
  it("falls back to the raw '/'..path before configure() is ever called", function()
    assets.reset()
    assert.equal(assets.url("assets/logo.png"), "/assets/logo.png")
  end)

  it("resolves a real manifest's hashed URL once configured", function()
    local path = write_temp_manifest([[
return {
  version = 1,
  assets = {
    ["assets/logo.png"] = { url = "/assets/logo.a1b2c3d4e5.png", integrity = "b3:a1b2c3d4e5" },
  },
  styles = {},
}
]])
    assets.configure(path)
    assert.equal(assets.url("assets/logo.png"), "/assets/logo.a1b2c3d4e5.png")
    os.remove(path)
  end)

  it("falls back to the raw path for a source path the manifest doesn't know about", function()
    local path = write_temp_manifest([[
return { version = 1, assets = {}, styles = {} }
]])
    assets.configure(path)
    assert.equal(assets.url("assets/unknown.png"), "/assets/unknown.png")
    os.remove(path)
  end)

  it("configure() with a nonexistent path degrades to the dev fallback rather than erroring", function()
    assets.configure("/nonexistent/path/hydronium-manifest.lua")
    assert.equal(assets.url("assets/logo.png"), "/assets/logo.png")
  end)

  it("reset() clears a previously configured manifest", function()
    local path = write_temp_manifest([[
return { version = 1, assets = { ["x.png"] = { url = "/x.HASH.png" } }, styles = {} }
]])
    assets.configure(path)
    assert.equal(assets.url("x.png"), "/x.HASH.png")
    assets.reset()
    assert.equal(assets.url("x.png"), "/x.png")
    os.remove(path)
  end)
end)
