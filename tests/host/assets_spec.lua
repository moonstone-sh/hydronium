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

  -- configure_table() is the BROWSER entry point: wasmoon has no filesystem,
  -- so configure()'s loadfile() cannot run client-side. mount()'s
  -- `assetManifestUrl` fetches the manifest, load()s it in the VM and calls
  -- this. Without it a static SPA silently serves the dev fallback URL for
  -- every asset -- a 404 with no SSR fallback behind it.
  it("configure_table() resolves an already-loaded manifest -- the browser path", function()
    assets.reset()
    -- Loaded from source, not a hand-built literal: this is exactly what
    -- mount() does to the real hydronium-manifest.lua inside the VM.
    -- NOTE: `assert` is the runner's assertion table here, not Lua's builtin.
    local chunk, err = load([[
return { version = 1, assets = { ["logo.svg"] = { url = "/assets/logo.deadbeef.svg" } }, styles = {} }
]])
    if not chunk then error("spec fixture: " .. tostring(err), 0) end
    local manifest = chunk()
    assets.configure_table(manifest)
    assert.equal(assets.url("logo.svg"), "/assets/logo.deadbeef.svg")
    assert.equal(assets.url("other.svg"), "/other.svg")
  end)

  it("configure_table() with a non-table degrades to the dev fallback, like a missing file", function()
    assets.configure_table(nil)
    assert.equal(assets.url("logo.svg"), "/logo.svg")
    assets.configure_table("not a manifest")
    assert.equal(assets.url("logo.svg"), "/logo.svg")
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
