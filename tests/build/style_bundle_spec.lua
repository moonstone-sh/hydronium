-- hydronium_ballad.plugins.style -- component-scoped CSS bundling.
--
-- Another plugin with no build-side coverage. tests/host/css_spec.lua covers
-- the hydronium_dom runtime's scope_class; nothing covered the build step that
-- rewrites a stylesheet's selectors to match it. The two MUST agree -- the
-- class a component gets at runtime and the class the CSS declares are derived
-- independently, and if they ever drift the page renders unstyled with no
-- error anywhere. Several tests below pin that agreement directly.

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local style = require("hydronium_ballad.plugins.style")
local site = require("hydronium_ballad.plugins.site")
local css_mod = require("hydronium_dom.css")
local graph = require("ballad.graph")

local function fake_ctx()
  return {
    graph = graph.Graph.new(),
    fail = function(message) error(message, 0) end,
    warn = function(_) end,
  }
end

local function sheet(store, virtual_path, content)
  return store:add_asset({
    kind = "file", generated = true, virtual_path = virtual_path, content = content,
  })
end

local function bundle(inputs, opts)
  local out = style.bundle(fake_ctx(), inputs, opts or { reset = false })
  return out.assets[1], out
end

describe("hydronium_ballad.plugins.style.bundle", function()
  it("scopes a class to exactly what hydronium_dom.css.scope_class produces", function()
    local store = graph.Graph.new()
    local asset = bundle({ { assets = { sheet(store, "views/App.css", ".card { color: red }") } } })
    -- Derived independently here and at runtime; if these ever disagree the
    -- page is silently unstyled, so assert the agreement rather than a shape.
    local expected = css_mod.scope_class("views/App.css", "card")
    assert.truthy(asset.content:find("." .. expected, 1, true),
      "scoped class missing; got: " .. asset.content)
    assert.falsy(asset.content:find("%.card%s"), "raw unscoped .card leaked through")
  end)

  it("leaves :global(...) unscoped and strips the wrapper", function()
    local store = graph.Graph.new()
    local asset = bundle({ { assets = { sheet(store, "a.css", ":global(.theme-dark) { color: #fff }") } } })
    assert.truthy(asset.content:find(".theme-dark", 1, true), "global class was scoped or lost")
    assert.falsy(asset.content:find(":global(", 1, true), "the :global() wrapper survived")
  end)

  it("does not rewrite class-looking text inside comments or strings", function()
    local store = graph.Graph.new()
    local asset = bundle({ { assets = { sheet(store, "a.css",
      '/* .commented */\n.real { content: ".quoted" }') } } })
    assert.truthy(asset.content:find("/* .commented */", 1, true), "a comment was rewritten")
    assert.truthy(asset.content:find('".quoted"', 1, true), "a string literal was rewritten")
    assert.truthy(asset.content:find("." .. css_mod.scope_class("a.css", "real"), 1, true))
  end)

  it("scopes the same class name differently per stylesheet -- that IS the scoping", function()
    local store = graph.Graph.new()
    local asset = bundle({ { assets = {
      sheet(store, "views/A.css", ".title { color: red }"),
      sheet(store, "views/B.css", ".title { color: blue }"),
    } } })
    local a = css_mod.scope_class("views/A.css", "title")
    local b = css_mod.scope_class("views/B.css", "title")
    assert.not_equal(a, b)
    assert.truthy(asset.content:find("." .. a, 1, true))
    assert.truthy(asset.content:find("." .. b, 1, true))
  end)

  it("emits one hy_style_bundle carrying the url site.manifest reads", function()
    local store = graph.Graph.new()
    local asset, out = bundle({ { assets = { sheet(store, "a.css", ".x{}") } } })
    assert.equal(#out.assets, 1)
    assert.equal(asset.kind, "hy_style_bundle")
    local h = asset.metadata.hydronium
    assert.equal(h.url, "/" .. asset.virtual_path)
    assert.equal(h.sheet_count, 1)
    assert.equal(h.reset, false)
    assert.truthy(asset.virtual_path:find("^assets/app%-%w+%.css$"),
      "unexpected bundle path: " .. asset.virtual_path)
  end)

  it("orders sheets deterministically, so the hash is stable across runs", function()
    local store = graph.Graph.new()
    local forward = bundle({ { assets = {
      sheet(store, "a.css", ".a{}"), sheet(store, "b.css", ".b{}") } } })
    local store2 = graph.Graph.new()
    local reversed = bundle({ { assets = {
      sheet(store2, "b.css", ".b{}"), sheet(store2, "a.css", ".a{}") } } })
    assert.equal(forward.virtual_path, reversed.virtual_path)
    assert.equal(forward.content, reversed.content)
  end)

  it("changes the hash when a stylesheet changes", function()
    local s1 = graph.Graph.new()
    local first = bundle({ { assets = { sheet(s1, "a.css", ".x { color: red }") } } })
    local s2 = graph.Graph.new()
    local second = bundle({ { assets = { sheet(s2, "a.css", ".x { color: blue }") } } })
    assert.not_equal(first.virtual_path, second.virtual_path)
  end)

  it("ignores non-CSS assets", function()
    local store = graph.Graph.new()
    local lua = store:add_asset({ kind = "hy_module", virtual_path = "m.lua", content = "return 1" })
    local asset = bundle({ { assets = { lua, sheet(store, "a.css", ".x{}") } } })
    assert.equal(asset.metadata.hydronium.sheet_count, 1)
    assert.falsy(asset.content:find("return 1", 1, true))
  end)

  it("emits nothing when there are no sheets and no reset", function()
    local out = style.bundle(fake_ctx(), { { assets = {} } }, { reset = false })
    assert.equal(#out.assets, 0)
  end)

  it("feeds site.manifest unchanged -- the real integration", function()
    local store = graph.Graph.new()
    local ctx = fake_ctx()
    local bundled = style.bundle(ctx, { { assets = { sheet(store, "a.css", ".x{}") } } }, { reset = false })
    local manifest = site.manifest(ctx, { bundled }, {})
    local json
    for _, a in ipairs(manifest.assets) do
      if a.virtual_path and a.virtual_path:find("%.json$") then json = a.content end
    end
    assert.is_not_nil(json, "site.manifest emitted no json")
    assert.truthy(json:find("assets/app-", 1, true), "manifest lost the stylesheet url")
  end)
end)
