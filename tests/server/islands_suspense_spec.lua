local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local H = require("hydronium")
local server = require("hydronium_dom.server")
local symbols = require("hydronium.core.symbols")
local resource = require("hydronium.core.resource")
local dom = require("hydronium_dom")
local d = dom.d

describe("Hydronium DOM Islands (d.lua / d.js)", function()
  it("exposes d.lua.island and d.js.island as immutable island descriptors, not intrinsics", function()
    assert.truthy(d.lua.island)
    assert.equal(d.lua.island["$$typeof"], symbols.ISLAND_DESCRIPTOR)
    assert.equal(d.lua.island.interpreter, "lua")

    assert.truthy(d.js.island)
    assert.equal(d.js.island["$$typeof"], symbols.ISLAND_DESCRIPTOR)
    assert.equal(d.js.island.interpreter, "js")

    -- Not an ordinary HTML intrinsic -- must not collide with a real <lua>/<js> tag
    assert.falsy(d.lua.island["$$typeof"] == symbols.INTRINSIC)
  end)

  it("exposes d.js.script as a script descriptor", function()
    assert.truthy(d.js.script)
    assert.equal(d.js.script["$$typeof"], symbols.SCRIPT_DESCRIPTOR)
  end)

  it("is an ordinary dotted-expression namespace -- caching d.lua does not create a fake <lua> HTML descriptor", function()
    -- Accessing d.lua must not populate the generic intrinsic cache the
    -- way accessing an unknown tag name like d.someCustomTag would.
    local lua_ns = d.lua
    assert.equal(lua_ns.island["$$typeof"], symbols.ISLAND_DESCRIPTOR)
    assert.falsy(pcall(function() lua_ns.island = nil end))
  end)

  it("d.lua.island(...) produces an ISLAND-kind VNode carrying interpreter metadata", function()
    local vnode = H.h(d.lua.island, { hydrate = "visible" }, H.h("div", nil, "hi"))
    assert.equal(vnode.kind, symbols.ISLAND)
    assert.equal(vnode.tag.interpreter, "lua")
  end)

  it("d.lua.mount(vnode) is a root-sized island", function()
    local App = function() return H.h("div", nil, "app") end
    local mounted = d.lua.mount(H.h(App))
    assert.equal(mounted.kind, symbols.ISLAND)
    assert.equal(mounted.tag.interpreter, "lua")
    assert.equal(mounted.props.root, true)
  end)
end)

describe("Hydronium SSR Island Rendering (v1: buffered, SSR-only)", function()
  it("wraps a Lua island's SSR output in stable-ID HTML comment markers", function()
    local vnode = H.h(d.lua.island, nil, H.h("button", nil, "Click"))
    local html = server.render_to_string(vnode)
    assert.truthy(html:find("<!--hy:i:hy:i1:lua-->", 1, true))
    assert.truthy(html:find("<!--hy:/i:hy:i1-->", 1, true))
    assert.truthy(html:find("<button>Click</button>", 1, true))
  end)

  it("records a ClientPlan island entry as render_to_string's second return value", function()
    local vnode = H.h(d.lua.island, { hydrate = "visible" }, H.h("span", nil, "x"))
    local html, plan = server.render_to_string(vnode)
    assert.truthy(html)
    assert.equal(plan.version, "hydronium.client-plan.v1")
    assert.equal(#plan.islands, 1)
    assert.equal(plan.islands[1].interpreter, "lua")
    assert.equal(plan.islands[1].hydrate, "visible")
  end)

  it("assigns distinct, deterministic (non-random, non-pointer) IDs to multiple islands in tree order", function()
    local vnode = H.h("div", nil,
      H.h(d.lua.island, nil, H.h("span", nil, "a")),
      H.h(d.js.island, { module = "./chart.js" }, H.h("span", nil, "b"))
    )
    local html, plan = server.render_to_string(vnode)
    assert.equal(#plan.islands, 2)
    assert.equal(plan.islands[1].id, "hy:i1")
    assert.equal(plan.islands[2].id, "hy:i2")
    assert.equal(plan.islands[2].interpreter, "js")
    assert.equal(plan.islands[2].module, "./chart.js")
    -- Second call starts a fresh sequence -- IDs are per-render, not global mutable state.
    local _, plan2 = server.render_to_string(H.h(d.lua.island, nil, "x"))
    assert.equal(plan2.islands[1].id, "hy:i1")
    assert.truthy(html)
  end)

  it("d.js.script registers a ClientPlan script record and renders no DOM element of its own", function()
    local vnode = H.h("div", nil, H.h(d.js.script, { src = "./analytics.js", type = "module" }))
    local html, plan = server.render_to_string(vnode)
    assert.truthy(html:find("^<div></div>", 1, false), html)
    assert.equal(#plan.scripts, 1)
    assert.equal(plan.scripts[1].src, "./analytics.js")
    assert.equal(plan.scripts[1].module, "./analytics.js")
  end)

  it("appends a __HYDRONIUM_CLIENT_PLAN__ script tag only when the page declares client surface", function()
    local ssr_only_html = server.render_to_string(H.h("div", nil, "hi"))
    assert.falsy(ssr_only_html:find("__HYDRONIUM_CLIENT_PLAN__", 1, true))

    local island_html = server.render_to_string(H.h(d.lua.island, nil, "hi"))
    assert.truthy(island_html:find('<script id="__HYDRONIUM_CLIENT_PLAN__" type="application/json">', 1, true))
    assert.truthy(island_html:find('"version":"hydronium.client%-plan.v1"'))
  end)

  it("suppress_client_plan_script omits the tag even when islands exist", function()
    local html = server.render_to_string(H.h(d.lua.island, nil, "hi"), { suppress_client_plan_script = true })
    assert.falsy(html:find("__HYDRONIUM_CLIENT_PLAN__", 1, true))
  end)

  it("a Lua event callback inside a Lua island does not raise the boundary diagnostic", function()
    local vnode = H.h(d.lua.island, nil, H.h("button", { onClick = function() end }, "ok"))
    local ok, html = pcall(server.render_to_string, vnode)
    assert.truthy(ok, tostring(html))
    assert.truthy(html:find("<button>ok</button>", 1, true))
  end)
end)

describe("Hydronium Suspense + Resource (v1: sequential/buffered SSR)", function()
  it("a resource with a loader resolves synchronously -- no fallback is ever visible", function()
    local res = resource.new(function() return "loaded" end)
    local Profile = function()
      return H.h("p", nil, res:get())
    end
    local vnode = H.h(H.Suspense, { fallback = H.h("p", nil, "loading...") }, H.h(Profile))
    local html = server.render_to_string(vnode)
    assert.equal(html, "<p>loaded</p>")
    assert.equal(res:status(), "ready")
  end)

  it("a manually-pending resource (no loader) renders the Suspense fallback", function()
    local res = resource.new()
    local Profile = function()
      return H.h("p", nil, res:get())
    end
    local vnode = H.h(H.Suspense, { fallback = H.h("p", nil, "loading...") }, H.h(Profile))
    local html = server.render_to_string(vnode)
    assert.equal(html, "<p>loading...</p>")
    assert.equal(res:status(), "pending")
  end)

  it("re-rendering after the resource resolves produces the real content instead", function()
    local res = resource.new()
    local Profile = function()
      return H.h("p", nil, res:get())
    end
    local vnode = function() return H.h(H.Suspense, { fallback = H.h("p", nil, "loading...") }, H.h(Profile)) end

    assert.equal(server.render_to_string(vnode()), "<p>loading...</p>")
    res:resolve("hello")
    assert.equal(server.render_to_string(vnode()), "<p>hello</p>")
  end)

  it("does not leak partial output from a subtree that ends up suspending", function()
    local res = resource.new()
    local Profile = function()
      return H.h("span", nil, res:get())
    end
    -- "before" must NOT appear in the output: it is a sibling inside the
    -- same Suspense boundary, rendered before Profile suspends, and must
    -- be discarded along with Profile's own (nonexistent) output.
    local vnode = H.h(H.Suspense, { fallback = H.h("p", nil, "fallback") },
      H.h("span", nil, "before"),
      H.h(Profile)
    )
    local html = server.render_to_string(vnode)
    assert.equal(html, "<p>fallback</p>")
  end)

  it("a failed resource is an ErrorBoundary concern, not a Suspense fallback", function()
    local res = resource.new(function() error("db down", 0) end)
    local Profile = function()
      return H.h("p", nil, res:get())
    end
    local vnode = H.h(H.ErrorBoundary, {
      fallback = function(err) return H.h("p", nil, "error: " .. tostring(err.message)) end,
    }, H.h(H.Suspense, { fallback = H.h("p", nil, "loading...") }, H.h(Profile)))
    local html = server.render_to_string(vnode)
    assert.truthy(html:find("error: db down", 1, true))
    assert.falsy(html:find("loading...", 1, true))
  end)

  it("a resource left pending with no enclosing Suspense raises a clear, distinct error", function()
    local res = resource.new()
    local Profile = function() return H.h("p", nil, res:get()) end
    local ok, err = pcall(server.render_to_string, H.h(Profile))
    assert.falsy(ok)
    assert.truthy(tostring(err):find("no enclosing", 1, true))
  end)

  it("isSuspension distinguishes a suspension signal from an ordinary error", function()
    local ok, err = pcall(function() error({ __hydronium_suspension = true, resource = 1 }, 0) end)
    assert.falsy(ok)
    assert.truthy(resource.isSuspension(err))
    local ok2, err2 = pcall(function() error("boom", 0) end)
    assert.falsy(resource.isSuspension(err2))
  end)
end)
