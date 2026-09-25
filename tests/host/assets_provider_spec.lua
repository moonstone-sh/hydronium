--[[
  hydronium_dom.assets -- the STEP 1 provider contract added by
  docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md: configure_provider()/provider()
  plus tags(entry), across all three providers ("static", "vite-dev",
  "vite-manifest"). tests/host/assets_spec.lua covers the pre-existing
  url()/configure()/configure_table() surface unchanged; this file covers
  only what STEP 1 adds.

  tags() is exercised through a REAL SSR render (hydronium_dom.server),
  not by inspecting vnode internals -- the whole point of returning real
  `d.link`/`d.script` elements is that they render through the ordinary
  html.lua attribute pipeline (alphabetically-sorted, escaped attrs) like
  any other element a component author writes.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local assets = require("hydronium_dom.assets")
local server = require("hydronium_dom.server")
local H = require("hydronium")

local function render_tags(entry)
  local vnode = H.h("head", nil, assets.tags(entry))
  local html = server.render_to_string(vnode)
  return html
end

local function write_temp_file(content, suffix)
  local path = os.tmpname() .. (suffix or "")
  local f = io.open(path, "w")
  f:write(content)
  f:close()
  return path
end

describe("hydronium_dom.assets -- provider()/configure_provider() defaults", function()
  it("defaults to the \"static\" provider with nothing configured", function()
    assets.reset()
    assert.equal(assets.provider(), "static")
  end)

  it("configure_provider({ provider = \"static\" }) with no path behaves like reset for url()", function()
    assets.reset()
    assets.configure_provider({ provider = "static" })
    assert.equal(assets.provider(), "static")
    assert.equal(assets.url("assets/logo.png"), "/assets/logo.png")
  end)

  it("configure()/configure_table() still set the provider to \"static\" (back-compat)", function()
    assets.reset()
    assets.configure_provider({ provider = "vite-dev", vite_origin = "http://localhost:5173" })
    assert.equal(assets.provider(), "vite-dev")
    assets.configure_table({ version = 1, assets = {}, styles = {} })
    assert.equal(assets.provider(), "static")
    assets.reset()
  end)

  it("rejects an unknown provider name", function()
    local ok = pcall(assets.configure_provider, { provider = "webpack" })
    assert.falsy(ok)
  end)

  it("reset() returns to the static default from any provider", function()
    assets.configure_provider({ provider = "vite-dev", vite_origin = "http://localhost:5173" })
    assets.reset()
    assert.equal(assets.provider(), "static")
    assert.equal(assets.url("x.js"), "/x.js")
  end)
end)

describe("hydronium_dom.assets.tags -- \"static\" provider", function()
  it("emits a single <link> for a CSS-only entry", function()
    local path = write_temp_file([[
return {
  version = 1,
  assets = { ["src/styles.css"] = { url = "/assets/styles.a1b2c3.css" } },
  styles = {},
}
]], ".lua")
    assets.configure_provider({ provider = "static", manifest_path = path })
    local html = render_tags("src/styles.css")
    assert.truthy(html:find('<link'), "expected a <link> tag")
    assert.truthy(html:find('href="/assets/styles.a1b2c3.css"', 1, true))
    assert.truthy(html:find('rel="stylesheet"', 1, true))
    assert.falsy(html:find("<script", 1, true))
    assets.reset()
    os.remove(path)
  end)

  it("emits a single <script type=module> for a JS entry", function()
    local path = write_temp_file([[
return {
  version = 1,
  assets = { ["src/main.js"] = { url = "/assets/main.deadbeef.js" } },
  styles = {},
}
]], ".lua")
    assets.configure_provider({ provider = "static", manifest_path = path })
    local html = render_tags("src/main.js")
    assert.truthy(html:find('<script', 1, true))
    assert.truthy(html:find('src="/assets/main.deadbeef.js"', 1, true))
    assert.truthy(html:find('type="module"', 1, true))
    assert.falsy(html:find("<link", 1, true))
    assets.reset()
    os.remove(path)
  end)

  it("falls back to the raw dev URL for an unconfigured/unknown entry (never raises)", function()
    assets.reset()
    local ok, html = pcall(render_tags, "src/unknown.js")
    assert.truthy(ok)
    assert.truthy(html:find('src="/src/unknown.js"', 1, true))
  end)
end)

describe("hydronium_dom.assets.tags -- \"vite-dev\" provider (dev origin)", function()
  it("prefixes the entry with the configured Vite origin", function()
    assets.configure_provider({ provider = "vite-dev", vite_origin = "http://localhost:5173" })
    local html = render_tags("src/main.js")
    assert.truthy(html:find('src="http://localhost:5173/src/main.js"', 1, true))
    assets.reset()
  end)

  it("also affects url() for the same entry (one config, both APIs)", function()
    assets.configure_provider({ provider = "vite-dev", vite_origin = "http://localhost:5173/" })
    assert.equal(assets.url("src/main.js"), "http://localhost:5173/src/main.js")
    assets.reset()
  end)

  it("detects a CSS entry by extension in dev too", function()
    assets.configure_provider({ provider = "vite-dev", vite_origin = "http://localhost:5173" })
    local html = render_tags("src/styles.css")
    assert.truthy(html:find('<link', 1, true))
    assert.truthy(html:find('href="http://localhost:5173/src/styles.css"', 1, true))
    assets.reset()
  end)
end)

describe("hydronium_dom.assets.tags -- \"vite-manifest\" provider", function()
  local function configure_fixture()
    local path = write_temp_file([[{
  "src/main.js": {
    "file": "assets/main.C0FFEE.js",
    "src": "src/main.js",
    "isEntry": true,
    "css": ["assets/main.BEEF01.css"],
    "imports": ["_shared.js"]
  },
  "_shared.js": {
    "file": "assets/shared.ABCDEF.js",
    "css": ["assets/shared.123456.css"]
  },
  "src/styles.css": {
    "file": "assets/styles.9999AA.css",
    "src": "src/styles.css",
    "isEntry": true
  }
}]], ".json")
    assets.configure_provider({ provider = "vite-manifest", manifest_path = path })
    return path
  end

  it("emits a single <link> for a CSS-only entry (no css/imports of its own)", function()
    local path = configure_fixture()
    local html = render_tags("src/styles.css")
    assert.truthy(html:find('<link', 1, true))
    assert.truthy(html:find('href="/assets/styles.9999AA.css"', 1, true))
    assert.falsy(html:find("<script", 1, true))
    assets.reset()
    os.remove(path)
  end)

  it("emits its own CSS, its transitive import's CSS, then its own script -- for a JS entry with css+imports", function()
    local path = configure_fixture()
    local html = render_tags("src/main.js")

    local own_css_pos = html:find('href="/assets/main.BEEF01.css"', 1, true)
    local shared_css_pos = html:find('href="/assets/shared.123456.css"', 1, true)
    local script_pos = html:find('src="/assets/main.C0FFEE.js"', 1, true)

    assert.truthy(own_css_pos, "own CSS must be present")
    assert.truthy(shared_css_pos, "transitively-imported chunk's CSS must be present")
    assert.truthy(script_pos, "the entry's own script tag must be present")
    -- CSS must precede the script (no flash of unstyled content).
    assert.truthy(own_css_pos < script_pos)
    assert.truthy(shared_css_pos < script_pos)
    -- The shared chunk's own JS file must NOT be emitted as a tag -- only
    -- entries a component actually asks for get a top-level tag; an
    -- imported chunk is pulled in by the browser's own module graph.
    assert.falsy(html:find("shared.ABCDEF.js", 1, true))

    assets.reset()
    os.remove(path)
  end)

  it("raises for an entry that is not in the manifest -- unlike url(), tags() fails loudly", function()
    local path = configure_fixture()
    local ok, err = pcall(assets.tags, "src/never-declared.js")
    assert.falsy(ok)
    assert.truthy(tostring(err):find("never%-declared%.js"))
    assets.reset()
    os.remove(path)
  end)

  it("raises when the provider is selected but no manifest could be read", function()
    assets.configure_provider({ provider = "vite-manifest", manifest_path = "/nonexistent/dist/.vite/manifest.json" })
    local ok = pcall(assets.tags, "src/main.js")
    assert.falsy(ok)
    assets.reset()
  end)

  it("url() for the same provider still uses the lenient dev-fallback contract", function()
    local path = configure_fixture()
    assert.equal(assets.url("src/main.js"), "/assets/main.C0FFEE.js")
    assert.equal(assets.url("src/never-declared.js"), "/src/never-declared.js")
    assets.reset()
    os.remove(path)
  end)

  it("honors a custom base URL prefix", function()
    local path = write_temp_file([[{"src/main.js": {"file": "assets/main.C0FFEE.js", "isEntry": true}}]], ".json")
    assets.configure_provider({ provider = "vite-manifest", manifest_path = path, base = "https://cdn.example.com/app" })
    assert.equal(assets.url("src/main.js"), "https://cdn.example.com/app/assets/main.C0FFEE.js")
    assets.reset()
    os.remove(path)
  end)
end)
