-- Tests for hydronium_ballad.plugins.vite_assets (M3 of
-- docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md): ingesting a real Vite
-- dist/.vite/manifest.json and re-emitting hy_asset entries matching
-- plugins.assets.hash's own output shape exactly, plus proving site.lua
-- needs zero changes to merge them.

local vite_assets = require("hydronium_ballad.plugins.vite_assets")
local site = require("hydronium_ballad.plugins.site")
local graph = require("ballad.graph")
local process = require("ballad.process")

local function fake_ctx()
  return {
    graph = graph.Graph.new(),
    -- Matches tests/build/client_require_discipline_spec.lua's own
    -- fake_ctx convention exactly: ctx.fail(msg) as a plain dot-call.
    fail = function(message) error(message, 0) end,
    warn = function(_) end,
  }
end

-- Writes real content to a real temp file and returns its path -- the
-- plugin reads manifest.json and b3sums built files off real disk, not
-- from in-memory `content`, so a faithful test needs real files.
local function write_temp_file(content, suffix)
  local path = os.tmpname() .. (suffix or "")
  local f = io.open(path, "w")
  f:write(content)
  f:close()
  return path
end

local function file_asset(store, virtual_path, source_path)
  return store:add_asset({ kind = "file", source_path = source_path, virtual_path = virtual_path })
end

describe("hydronium_ballad.plugins.vite_assets", function()
  it("passes every input through unchanged when no manifest.json is present (graceful degradation, hazard #1)", function()
    local store = graph.Graph.new()
    local logo_path = write_temp_file("fake-image-bytes", ".png")
    local logo = file_asset(store, "assets/logo.png", logo_path)

    local result = vite_assets.ingest(fake_ctx(), { { assets = { logo } } }, {})

    assert.equal(#result.assets, 1)
    assert.equal(result.assets[1].kind, "file")
    assert.equal(result.assets[1].virtual_path, "assets/logo.png")
    os.remove(logo_path)
  end)

  it("re-emits a manifest entry as an hy_asset matching plugins.assets.hash's exact shape", function()
    local store = graph.Graph.new()
    local js_path = write_temp_file("console.log('hi')", ".js")
    local manifest_json = [[{"src/counter-island.js":{"file":"assets/counter-island-abc123.js","isEntry":true}}]]
    local manifest_path = write_temp_file(manifest_json, ".json")

    local manifest_asset = file_asset(store, ".vite/manifest.json", manifest_path)
    local built_asset = file_asset(store, "assets/counter-island-abc123.js", js_path)

    local result = vite_assets.ingest(fake_ctx(), { { assets = { manifest_asset, built_asset } } }, {})

    assert.equal(#result.assets, 1)
    local asset = result.assets[1]
    assert.equal(asset.kind, "hy_asset")
    assert.equal(asset.source_path, js_path)
    assert.equal(asset.virtual_path, "assets/counter-island-abc123.js")

    local h = asset.metadata.hydronium
    assert.equal(h.kind, "asset")
    assert.equal(h.source, "src/counter-island.js")
    assert.equal(h.url, "/assets/counter-island-abc123.js")
    assert.equal(h.integrity, "b3:" .. process.b3sum(js_path))

    os.remove(js_path)
    os.remove(manifest_path)
  end)

  it("drops the manifest.json itself from the output (build-internal, not a servable asset)", function()
    local store = graph.Graph.new()
    local manifest_path = write_temp_file("{}", ".json")
    local manifest_asset = file_asset(store, ".vite/manifest.json", manifest_path)

    local result = vite_assets.ingest(fake_ctx(), { { assets = { manifest_asset } } }, {})

    assert.equal(#result.assets, 0)
    os.remove(manifest_path)
  end)

  it("also re-emits an entry's css siblings, keyed by their own built path", function()
    local store = graph.Graph.new()
    local js_path = write_temp_file("console.log('hi')", ".js")
    local css_path = write_temp_file("body{color:red}", ".css")
    local manifest_json = string.format(
      [[{"src/main.js":{"file":"assets/main-deadbeef.js","isEntry":true,"css":["assets/main-cafe0.css"]}}]]
    )
    local manifest_path = write_temp_file(manifest_json, ".json")

    local manifest_asset = file_asset(store, ".vite/manifest.json", manifest_path)
    local js_asset = file_asset(store, "assets/main-deadbeef.js", js_path)
    local css_asset = file_asset(store, "assets/main-cafe0.css", css_path)

    local result = vite_assets.ingest(fake_ctx(), { { assets = { manifest_asset, js_asset, css_asset } } }, {})

    assert.equal(#result.assets, 2)
    local by_source = {}
    for _, asset in ipairs(result.assets) do
      by_source[asset.metadata.hydronium.source] = asset
    end
    assert.truthy(by_source["src/main.js"])
    assert.equal(by_source["src/main.js"].metadata.hydronium.url, "/assets/main-deadbeef.js")
    assert.truthy(by_source["assets/main-cafe0.css"])
    assert.equal(by_source["assets/main-cafe0.css"].metadata.hydronium.url, "/assets/main-cafe0.css")

    os.remove(js_path)
    os.remove(css_path)
    os.remove(manifest_path)
  end)

  it("passes through a built file the manifest never named (e.g. a public/ copy), unre-tagged", function()
    local store = graph.Graph.new()
    local manifest_path = write_temp_file("{}", ".json")
    local favicon_path = write_temp_file("fake-ico-bytes", ".ico")

    local manifest_asset = file_asset(store, ".vite/manifest.json", manifest_path)
    local favicon_asset = file_asset(store, "favicon.ico", favicon_path)

    local result = vite_assets.ingest(fake_ctx(), { { assets = { manifest_asset, favicon_asset } } }, {})

    assert.equal(#result.assets, 1)
    assert.equal(result.assets[1].kind, "file")
    assert.equal(result.assets[1].virtual_path, "favicon.ico")

    os.remove(manifest_path)
    os.remove(favicon_path)
  end)

  it("accepts a custom manifest_path option", function()
    local store = graph.Graph.new()
    local js_path = write_temp_file("x", ".js")
    local manifest_json = [[{"src/x.js":{"file":"assets/x-hash.js"}}]]
    local manifest_path = write_temp_file(manifest_json, ".json")

    local manifest_asset = file_asset(store, "custom/manifest.json", manifest_path)
    local built_asset = file_asset(store, "assets/x-hash.js", js_path)

    local result = vite_assets.ingest(
      fake_ctx(),
      { { assets = { manifest_asset, built_asset } } },
      { manifest_path = "custom/manifest.json" }
    )

    assert.equal(#result.assets, 1)
    assert.equal(result.assets[1].metadata.hydronium.source, "src/x.js")

    os.remove(js_path)
    os.remove(manifest_path)
  end)

  it("site.lua's manifest merge needs ZERO changes: feeding vite_assets' output straight into "
    .. "site.manifest picks it up via the same generic hy_asset/metadata.hydronium.source loop "
    .. "every other hy_asset producer already uses", function()
    local store = graph.Graph.new()
    local js_path = write_temp_file("console.log('hi')", ".js")
    local manifest_json = [[{"src/counter-island.js":{"file":"assets/counter-island-abc123.js"}}]]
    local manifest_path = write_temp_file(manifest_json, ".json")

    local manifest_asset = file_asset(store, ".vite/manifest.json", manifest_path)
    local built_asset = file_asset(store, "assets/counter-island-abc123.js", js_path)

    local vite_out = vite_assets.ingest(fake_ctx(), { { assets = { manifest_asset, built_asset } } }, {})
    local site_out = site.manifest(fake_ctx(), { vite_out }, { name = "manifest" })

    local json
    for _, asset in ipairs(site_out.assets) do
      if asset.virtual_path == "manifest.json" then json = asset.content end
    end
    assert.truthy(json)
    assert.truthy(json:find('"src/counter-island.js"', 1, true))
    assert.truthy(json:find('"/assets/counter-island-abc123.js"', 1, true))

    os.remove(js_path)
    os.remove(manifest_path)
  end)
end)
