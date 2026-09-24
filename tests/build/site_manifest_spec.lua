local graph = require("ballad.graph")
local site = require("hydronium_ballad.plugins.site")

local function ctx()
  return {
    graph = graph.Graph.new(),
    fail = function(message) error(message, 0) end,
    warn = function(_) end,
  }
end

--- A minimal hy_chunk asset shaped like client.bundle's real output
--- (build/src/hydronium_ballad/plugins/client.lua's bundle_single): the
--- only fields site.manifest's mount handling reads are virtual_path and
--- metadata.hydronium.entry.
local function chunk_asset(store, virtual_path, entry)
  return store:add_asset({
    kind = "hy_chunk", generated = true, virtual_path = virtual_path,
    metadata = { hydronium = { entry = entry } },
  })
end

local function find_asset(result, virtual_path)
  for _, asset in ipairs(result.assets) do
    if asset.virtual_path == virtual_path then return asset end
  end
  return nil
end

describe("hydronium_ballad.plugins.site manifest", function()
  it("publishes client module semantics without source origins", function()
    local assets = graph.Graph.new()
    local module = assets:add_asset({
      kind = "hy_module", generated = true, virtual_path = "app.lua", content = "return {}",
      metadata = { hydronium = {
        module_id = "app", origin = "/private/project/src/App.luax", target = "client",
        transform = "luax", update = "hot", revision = "b3-test",
        effects = "safe",
      } },
    })
    local result = site.manifest(ctx(), { { assets = { module } } }, { name = "manifest" })
    local json
    for _, asset in ipairs(result.assets) do
      if asset.virtual_path == "manifest.json" then json = asset.content end
    end
    assert.truthy(json)
    assert.truthy(json:find('"app"', 1, true))
    assert.truthy(json:find('"hot"', 1, true))
    assert.truthy(json:find('"safe"', 1, true))
    assert.falsy(json:find("/private/project", 1, true))
  end)

  -- M4: index.html emission is opt-in (`mount`), derived from the same
  -- hy_chunk/hy_style_bundle data the manifest itself is built from.
  it("emits no index.html when mount is not requested, even with a mountable chunk present", function()
    local store = graph.Graph.new()
    local chunk = chunk_asset(store, "client/runtime-abc123.lua", "app")
    local result = site.manifest(ctx(), { { assets = { chunk } } }, {})
    assert.is_nil(find_asset(result, "index.html"))
  end)

  it("emits index.html wired to the real chunk url and entry when mount is requested", function()
    local store = graph.Graph.new()
    local chunk = chunk_asset(store, "client/runtime-abc123.lua", "app")
    local result = site.manifest(ctx(), { { assets = { chunk } } }, {
      name = "manifest", mount = { title = "Test App" },
    })
    local html = find_asset(result, "index.html")
    assert.truthy(html, "no index.html emitted")
    assert.truthy(html.content:find("<title>Test App</title>", 1, true))
    assert.truthy(html.content:find('chunkUrls: ["/client/runtime-abc123.lua"]', 1, true))
    assert.truthy(html.content:find('appModuleId: "app"', 1, true))
    assert.truthy(html.content:find('assetManifestUrl: "/manifest.lua"', 1, true))
    assert.truthy(html.content:find('hydrate: false', 1, true))
  end)

  it("wires the stylesheet link and lua_globals import when both are present", function()
    local store = graph.Graph.new()
    local chunk = chunk_asset(store, "client/runtime-abc123.lua", "app")
    local style_bundle = store:add_asset({
      kind = "hy_style_bundle", generated = true, virtual_path = "assets/app-xyz.css",
      metadata = { hydronium = { url = "/assets/app-xyz.css", sheet_count = 1, reset = false } },
    })
    local result = site.manifest(ctx(), { { assets = { chunk, style_bundle } } }, {
      mount = {
        lua_globals = { module = "/js/router/hash_history.js", import = "createHashHistoryGlobals" },
      },
    })
    local html = find_asset(result, "index.html").content
    assert.truthy(html:find('<link rel="stylesheet" href="/assets/app-xyz.css">', 1, true))
    assert.truthy(html:find('import { createHashHistoryGlobals } from "/js/router/hash_history.js"', 1, true))
    assert.truthy(html:find("luaGlobals: createHashHistoryGlobals()", 1, true))
  end)

  it("skips index.html silently when mount is requested but no chunk declares an entry", function()
    local result = site.manifest(ctx(), { { assets = {} } }, { mount = {} })
    assert.is_nil(find_asset(result, "index.html"))
  end)

  it("fails loudly when mount is requested and more than one chunk declares an entry", function()
    local store = graph.Graph.new()
    local a = chunk_asset(store, "client/one.lua", "app_one")
    local b = chunk_asset(store, "client/two.lua", "app_two")
    assert.has_error(function()
      site.manifest(ctx(), { { assets = { a, b } } }, { mount = {} })
    end, "ambiguous")
  end)

  it("mount = false behaves exactly like mount omitted", function()
    local store = graph.Graph.new()
    local chunk = chunk_asset(store, "client/runtime-abc123.lua", "app")
    local result = site.manifest(ctx(), { { assets = { chunk } } }, { mount = false })
    assert.is_nil(find_asset(result, "index.html"))
  end)

  -- mount.vendor: dist/ must be deployable to a dumb static file server
  -- with nothing else running (docs/HYDRONIUM_SPA_MODE_PLAN.md section
  -- 2.1) -- index.html references js_bootstrap_url/lua_globals.module as
  -- absolute site paths, so whatever serves those bytes has to actually be
  -- IN the sink. Verified for real against examples/spa_hash_demo's own
  -- build: a bare `python3 -m http.server` inside dist/ 404'd on both
  -- before mount.vendor existed.
  local function write_file(path, content)
    local f = io.open(path, "w")
    f:write(content)
    f:close()
  end

  it("mount.vendor copies a real directory tree into the sink under url_prefix", function()
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/hy_site_vendor_spec_" .. tostring(os.clock()):gsub("%.", "")
    os.execute("mkdir -p " .. dir .. "/sub")
    write_file(dir .. "/mount.js", "export function mount() {}")
    write_file(dir .. "/sub/nested.js", "export const x = 1;")

    local store = graph.Graph.new()
    local chunk = chunk_asset(store, "client/runtime-abc123.lua", "app")
    local result = site.manifest(ctx(), { { assets = { chunk } } }, {
      mount = { vendor = { { dir = dir, url_prefix = "js/bootstrap" } } },
    })

    local top = find_asset(result, "js/bootstrap/mount.js")
    assert.truthy(top, "top-level vendored file missing")
    assert.equal(top.kind, "file")
    -- Compared through ballad's own path.normalize, not string equality --
    -- site.lua legitimately runs fs.list_files/path.relative on `dir`,
    -- which collapses a double slash (TMPDIR often already ends in "/")
    -- that this test's own naive string concatenation does not.
    assert.equal(require("ballad.path").normalize(top.source_path),
      require("ballad.path").normalize(dir .. "/mount.js"))

    local nested = find_asset(result, "js/bootstrap/sub/nested.js")
    assert.truthy(nested, "nested vendored file missing -- relative structure must be preserved")
  end)

  it("mount.vendor with a leading/trailing slash in url_prefix normalizes the same way", function()
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/hy_site_vendor_spec_slash_" .. tostring(os.clock()):gsub("%.", "")
    os.execute("mkdir -p " .. dir)
    write_file(dir .. "/a.js", "1")

    local store = graph.Graph.new()
    local chunk = chunk_asset(store, "client/runtime-abc123.lua", "app")
    local result = site.manifest(ctx(), { { assets = { chunk } } }, {
      mount = { vendor = { { dir = dir, url_prefix = "/js/router/" } } },
    })
    assert.truthy(find_asset(result, "js/router/a.js"))
  end)

  it("fails loudly rather than silently shipping nothing when a vendor dir is missing or empty", function()
    local empty_dir = (os.getenv("TMPDIR") or "/tmp") .. "/hy_site_vendor_spec_empty_" .. tostring(os.clock()):gsub("%.", "")
    os.execute("mkdir -p " .. empty_dir)
    local store = graph.Graph.new()
    local chunk = chunk_asset(store, "client/runtime-abc123.lua", "app")
    assert.has_error(function()
      site.manifest(ctx(), { { assets = { chunk } } }, {
        mount = { vendor = { { dir = empty_dir, url_prefix = "js/bootstrap" } } },
      })
    end)
    assert.has_error(function()
      site.manifest(ctx(), { { assets = { chunk } } }, {
        mount = { vendor = { { dir = "/does/not/exist/at/all", url_prefix = "js/bootstrap" } } },
      })
    end)
  end)

  it("does not vendor anything when mount is requested but there is no chunk to mount", function()
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/hy_site_vendor_spec_unused_" .. tostring(os.clock()):gsub("%.", "")
    os.execute("mkdir -p " .. dir)
    write_file(dir .. "/a.js", "1")
    local result = site.manifest(ctx(), { { assets = {} } }, {
      mount = { vendor = { { dir = dir, url_prefix = "js/bootstrap" } } },
    })
    assert.is_nil(find_asset(result, "js/bootstrap/a.js"))
  end)
end)
