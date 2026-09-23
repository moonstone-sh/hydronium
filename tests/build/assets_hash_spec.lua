-- hydronium_ballad.plugins.assets -- content-hashed static files.
--
-- This plugin had NO build-side coverage. tests/host/assets_spec.lua covers
-- the hydronium_dom runtime that READS a manifest; nothing covered the plugin
-- that WRITES one. That gap matters most for SPA mode: with no SSR there is
-- no server-rendered fallback, so a wrong asset URL is a blank page.

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local assets = require("hydronium_ballad.plugins.assets")
local site = require("hydronium_ballad.plugins.site")
local graph = require("ballad.graph")

local function fake_ctx()
  return {
    graph = graph.Graph.new(),
    fail = function(message) error(message, 0) end,
    warn = function(_) end,
  }
end

local TMP = os.getenv("TMPDIR") or "/tmp"

local function write_file(name, content)
  local path = TMP .. "/hy_assets_spec_" .. name
  -- NOTE: `assert` is the runner's assertion table here, not Lua's builtin.
  local f, err = io.open(path, "w")
  if not f then error("spec fixture: cannot write " .. path .. ": " .. tostring(err), 0) end
  f:write(content)
  f:close()
  return path
end

local function file_asset(store, source_path, virtual_path)
  return store:add_asset({ kind = "file", source_path = source_path, virtual_path = virtual_path })
end

local function only(set)
  assert.equal(#set.assets, 1)
  return set.assets[1]
end

describe("hydronium_ballad.plugins.assets.hash", function()
  it("emits the hy_asset shape site.manifest joins on", function()
    local store = graph.Graph.new()
    local path = write_file("logo.png", "PNGDATA")
    local out = assets.hash(fake_ctx(), { { assets = { file_asset(store, path, "img/logo.png") } } }, {})
    local asset = only(out)

    assert.equal(asset.kind, "hy_asset")
    local h = asset.metadata.hydronium
    -- `source` is the join key: the path as the partiture declared it, which
    -- is what a component references and what assets.url() looks up.
    assert.equal(h.source, "img/logo.png")
    assert.equal(h.url, "/" .. asset.virtual_path)
    assert.truthy(h.integrity:find("^b3:"))
  end)

  it("keeps the stem and extension so a hashed file is still recognizable", function()
    local store = graph.Graph.new()
    local path = write_file("logo2.png", "PNGDATA")
    local asset = only(assets.hash(fake_ctx(), { { assets = { file_asset(store, path, "img/logo.png") } } }, {}))
    -- assets/logo.<digest>.png -- not logo.png.<digest>, and not a bare hash.
    assert.truthy(asset.virtual_path:find("^assets/logo%.%w+%.png$"),
      "unexpected hashed name: " .. asset.virtual_path)
  end)

  it("derives the hash from CONTENT, so identical bytes hash identically", function()
    local store = graph.Graph.new()
    local a = only(assets.hash(fake_ctx(), { { assets = {
      file_asset(store, write_file("same_a.txt", "identical"), "a.txt") } } }, {}))
    local b = only(assets.hash(fake_ctx(), { { assets = {
      file_asset(store, write_file("same_b.txt", "identical"), "b.txt") } } }, {}))
    assert.equal(a.metadata.hydronium.integrity, b.metadata.hydronium.integrity)
  end)

  it("changes the hash when the content changes -- the whole point of hashing", function()
    local store = graph.Graph.new()
    local first = only(assets.hash(fake_ctx(), { { assets = {
      file_asset(store, write_file("v.txt", "one"), "v.txt") } } }, {}))
    local second = only(assets.hash(fake_ctx(), { { assets = {
      file_asset(store, write_file("v2.txt", "two"), "v.txt") } } }, {}))
    assert.not_equal(first.virtual_path, second.virtual_path)
    assert.not_equal(first.metadata.hydronium.integrity, second.metadata.hydronium.integrity)
  end)

  it("honours out_prefix and hash_length", function()
    local store = graph.Graph.new()
    local asset = only(assets.hash(fake_ctx(), { { assets = {
      file_asset(store, write_file("x.css", "body{}"), "x.css") } } },
      { out_prefix = "static/", hash_length = 4 }))
    local digest = asset.virtual_path:match("^static/x%.(%w+)%.css$")
    assert.truthy(digest, "unexpected path: " .. asset.virtual_path)
    assert.equal(#digest, 4)
  end)

  it("passes non-file assets through untouched instead of hashing them", function()
    -- This is a pipeline stage: a Lua chunk or style bundle flowing past must
    -- arrive unchanged, not be dropped and not be given a bogus digest.
    local store = graph.Graph.new()
    local generated = store:add_asset({ kind = "hy_module", virtual_path = "m.lua", content = "return 1" })
    local out = assets.hash(fake_ctx(), { { assets = { generated } } }, {})
    assert.equal(#out.assets, 1)
    assert.equal(out.assets[1].kind, "hy_module")
    assert.equal(out.assets[1].virtual_path, "m.lua")
    assert.is_nil(out.assets[1].metadata and out.assets[1].metadata.hydronium)
  end)

  it("feeds site.manifest unchanged -- the real integration", function()
    local store = graph.Graph.new()
    local ctx = fake_ctx()
    local hashed = assets.hash(ctx, { { assets = {
      file_asset(store, write_file("m.png", "BYTES"), "img/m.png") } } }, {})
    local manifest = site.manifest(ctx, { hashed }, {})

    local json
    for _, a in ipairs(manifest.assets) do
      if a.virtual_path and a.virtual_path:find("%.json$") then json = a.content end
    end
    assert.is_not_nil(json, "site.manifest emitted no json")
    -- Keyed by the DECLARED path, valued by the hashed URL: that mapping is
    -- exactly what hydronium_dom.assets.url() resolves at runtime.
    assert.truthy(json:find('"img/m.png"', 1, true), "manifest lost the source key")
    assert.truthy(json:find("assets/m.", 1, true), "manifest lost the hashed url")
  end)
end)
