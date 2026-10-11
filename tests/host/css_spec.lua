--[[
  hydronium_dom.css -- real scoped-class computation, verified against
  the exact behavior hydronium_ballad.plugins.style's build-time CSS
  rewriter depends on agreeing with (see
  docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 2 and that plugin's own
  tests, which are ballad-graph-based and live outside this native suite
  -- this file covers the runtime half in isolation).
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local css = require("hydronium_dom.css")

describe("hydronium_dom.css -- scoped class computation", function()
  it("scope_class is deterministic for the same path+class", function()
    local a = css.scope_class("src/views/Header.css", "showcase-header")
    local b = css.scope_class("src/views/Header.css", "showcase-header")
    assert.equal(a, b)
  end)

  it("scope_class differs across different files for the same class name", function()
    local a = css.scope_class("src/views/Header.css", "title")
    local b = css.scope_class("src/views/Footer.css", "title")
    assert.truthy(a ~= b, "the same class name in two different files must not collide")
  end)

  it("scope_class differs across different class names in the same file", function()
    local a = css.scope_class("src/views/Header.css", "title")
    local b = css.scope_class("src/views/Header.css", "subtitle")
    assert.truthy(a ~= b)
  end)

  it("the scoped name embeds the real basename and the underscore-converted class name, for readability", function()
    local scoped = css.scope_class("src/views/Header.css", "nav-link")
    assert.truthy(scoped:match("^Header_"), "expected a Header_ prefix, got " .. scoped)
    assert.truthy(scoped:find("nav_link", 1, true), "expected the hyphen converted to an underscore, got " .. scoped)
  end)

  it("sheet(path) computes scoped names on demand with no file I/O -- indexing with any key works", function()
    local s = css.sheet("src/views/Header.css")
    assert.equal(s.showcase_header, css.scope_class("src/views/Header.css", "showcase-header"))
  end)

  it("sheet(path) unifies dot-access (underscore) and bracket-access (hyphenated) for the same real class", function()
    local s = css.sheet("src/views/Header.css")
    assert.equal(s.nav_link, s["nav-link"])
  end)

  it("sheet(path) results are read-only", function()
    local s = css.sheet("src/views/Header.css")
    local ok = pcall(function() s.foo = "bar" end)
    assert.falsy(ok, "assigning into a css.sheet() result must fail")
  end)

  it("two sheet() calls for the same path produce identical scoped names (no per-call random/pointer identity)", function()
    local s1 = css.sheet("src/views/Header.css")
    local s2 = css.sheet("src/views/Header.css")
    assert.equal(s1.title, s2.title)
  end)
end)


describe("Lua stylesheet imports", function()
  local assets = require("hydronium_dom.assets")
  it("resolves its subscription through the active provider at render time", function()
    local styles = css.import("src/global.css")
    assets.configure_provider({provider="vite-manifest", base="/public/dist", manifest_table={
      ["src/global.css"]={file="assets/global-123.css"},
    }})
    assert.equal(styles:url(), "/public/dist/assets/global-123.css")
    local nodes = styles:subscribe()
    assert.equal(#nodes, 1)
    assert.equal(nodes[1].props.href, "/public/dist/assets/global-123.css")
    assets.reset()
  end)
  it("subscribes to Vite's live stylesheet and HMR in development", function()
    assets.configure_provider({provider="vite-dev",vite_origin="http://localhost:5173"})
    local nodes = css.import("src/global.css"):subscribe()
    assert.equal(#nodes, 2)
    assert.equal(nodes[2].props.href, "http://localhost:5173/src/global.css")
    assets.reset()
  end)
  it("rejects a non-stylesheet import", function()
    assert.falsy(pcall(css.import, "src/app.js"))
  end)
end)


describe("Lua CSS Modules imports", function()
  local assets = require("hydronium_dom.assets")
  it("uses the build's actual class exports, including composition", function()
    local styles = css.import("src/Card.module.css")
    assets.configure_provider({provider="vite-manifest",manifest_table={
      ["src/Card.module.css"]={file="assets/card.css",classes={card="_card_123 _base_456"}},
    }})
    assert.equal(styles.classes.card, "_card_123 _base_456")
    assets.reset()
  end)
  it("uses development module exports and rejects a missing map", function()
    assets.configure_provider({provider="vite-dev",vite_origin="http://localhost:5173",
      module_classes={["src/Card.module.css"]={card="_card_dev"}}})
    assert.equal(css.import("src/Card.module.css").classes.card, "_card_dev")
    assets.reset()
    assert.falsy(pcall(function() return css.import("src/Card.module.css").classes end))
  end)
end)


describe("browser CSS Modules manifest", function()
  it("retains classes and stylesheet subscriptions in a serialized static manifest", function()
    local assets = require("hydronium_dom.assets")
    assets.configure_table({assets={["src/Card.module.css"]={url="/assets/card.js",
      classes={card="card_123"},css={"/assets/card.css"}}}})
    local styles = css.import("src/Card.module.css")
    assert.equal(styles.classes.card,"card_123")
    assert.equal(styles:subscribe()[1].props.href,"/assets/card.css")
    assets.reset()
  end)
end)
