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
    assert.equal(mounted.props.module, nil)
  end)

  it("d.lua.mount(vnode, opts) accepts an optional module id alongside root=true -- needed by "
    .. "hydronium_ballad.plugins.client's code-splitting (see docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md), "
    .. "which has no other way to learn a root-mounted app's own entry module id", function()
    local App = function() return H.h("div", nil, "app") end
    local mounted = d.lua.mount(H.h(App), { module = "app.client.root", mode = "replace", hydrate = "visible" })
    assert.equal(mounted.kind, symbols.ISLAND)
    assert.equal(mounted.props.root, true)
    assert.equal(mounted.props.module, "app.client.root")
    assert.equal(mounted.props.mode, "replace")
    assert.equal(mounted.props.hydrate, "visible")
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

  it("records a root-mounted d.lua.mount's module id in the ClientPlan, when given one", function()
    local App = function() return H.h("div", nil, "app") end
    local html, plan = server.render_to_string(d.lua.mount(H.h(App), { module = "app.client.root" }))
    assert.truthy(html)
    assert.equal(#plan.islands, 1)
    assert.equal(plan.islands[1].root, true)
    assert.equal(plan.islands[1].module, "app.client.root")
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

describe("Hydronium Suspense v2: coroutine-based resume-in-place", function()
  it("onSuspend resolving synchronously produces real content in one call, with no fallback shown", function()
    local res = resource.new()
    local Profile = function()
      return H.h("p", nil, res:get())
    end
    local vnode = H.h(H.Suspense, {
      fallback = H.h("p", nil, "loading..."),
      onSuspend = function(r) r:resolve("hello") end,
    }, H.h(Profile))
    local html = server.render_to_string(vnode)
    assert.equal(html, "<p>hello</p>")
    assert.falsy(html:find("loading", 1, true))
  end)

  it("preserves already-rendered sibling output across a resume instead of recomputing it", function()
    local res = resource.new()
    local render_count = 0
    local Sibling = function()
      render_count = render_count + 1
      return H.h("span", nil, "before")
    end
    local Profile = function()
      return H.h("span", nil, res:get())
    end
    local vnode = H.h(H.Suspense, {
      fallback = H.h("p", nil, "loading..."),
      onSuspend = function(r) r:resolve("after") end,
    }, H.h(Sibling), H.h(Profile))
    local html = server.render_to_string(vnode)
    assert.equal(html, "<span>before</span><span>after</span>")
    assert.equal(render_count, 1)
  end)

  it("a render error raised from onSuspend's own resolve still reaches the nearest ErrorBoundary", function()
    local res = resource.new()
    local Profile = function()
      return H.h("p", nil, res:get())
    end
    local vnode = H.h(H.ErrorBoundary, {
      fallback = function(err) return H.h("p", nil, "error: " .. tostring(err.message)) end,
    }, H.h(H.Suspense, {
      fallback = H.h("p", nil, "loading..."),
      onSuspend = function() error("resolve failed", 0) end,
    }, H.h(Profile)))
    local ok, html = pcall(server.render_to_string, vnode)
    assert.truthy(ok, tostring(html))
    assert.truthy(html:find("error: resolve failed", 1, true))
  end)

  it("with no onSuspend, behavior is unchanged from v1 and a later resolve does not error", function()
    local res = resource.new()
    local Profile = function()
      return H.h("p", nil, res:get())
    end
    local vnode = H.h(H.Suspense, { fallback = H.h("p", nil, "loading...") }, H.h(Profile))
    local html = server.render_to_string(vnode)
    assert.equal(html, "<p>loading...</p>")
    -- Nothing declared intent to resume (no onSuspend), so no waiter was
    -- registered -- resolving afterward is a harmless no-op from the
    -- caller's point of view, exactly as in v1.
    local ok = pcall(function() res:resolve("late") end)
    assert.truthy(ok)
  end)
end)

-- The specs above only ever exercise the SYNCHRONOUS resolve path, where
-- onSuspend settles the resource during its own call and the boundary
-- resumes in place. These cover the deferred path -- a resolve arriving
-- after the boundary already committed its fallback -- which is where
-- every serious v2 bug lived.
describe("Hydronium Suspense v2: deferred (post-fallback) resolution", function()
  -- Captures suspense diagnostics for the duration of `fn`, always
  -- restoring the previous handler.
  local function withDiagnostics(fn)
    local seen = {}
    local previous = resource.setSuspenseDiagnosticHandler(function(diag)
      table.insert(seen, diag)
    end)
    local ok, err = pcall(fn, seen)
    resource.setSuspenseDiagnosticHandler(previous)
    if not ok then error(err, 0) end
    return seen
  end

  local function findDiagnostic(seen, code)
    for i = 1, #seen do
      if seen[i].code == code then return seen[i] end
    end
    return nil
  end

  -- REGRESSION (CRITICAL): drive() returned false, the fallback was
  -- written, then the registered waiter resumed the coroutine, which
  -- flushed its buffer into the still-live write_fn. The output carried
  -- BOTH the fallback and the real content, with the real content landing
  -- wherever in tree order the resolve happened to occur.
  it("does not duplicate output when a sibling resolves the resource mid-pass", function()
    local seen = withDiagnostics(function()
      local res = resource.new()
      local stash = nil
      local Profile = function() return H.h("p", nil, res:get()) end
      local Later = function()
        if stash then stash:resolve("LATE-REAL") end
        return H.h("i", nil, "sibling")
      end

      local html = server.render_to_string(H.h("div", nil,
        H.h(H.Suspense, {
          fallback = H.h("p", nil, "loading..."),
          onSuspend = function(r) stash = r end,
        }, H.h(Profile)),
        H.h(Later)
      ))

      -- The fallback, exactly once, in its correct position -- and the
      -- resumed content nowhere at all.
      assert.equal(html, "<div><p>loading...</p><i>sibling</i></div>")
      assert.falsy(html:find("LATE-REAL", 1, true))
    end)

    -- Discarding it is deliberate, so it is reported rather than silent.
    local diag = findDiagnostic(seen, "suspense.late_resolve")
    assert.is_not_nil(diag)
    -- The owning render was still in flight when the resolve arrived.
    assert.falsy(diag.after_render)
  end)

  -- REGRESSION (MEDIUM): the resumed coroutine wrote real content into a
  -- buffer table the caller had already concatenated and thrown away. No
  -- error, no diagnostic -- the output simply vanished.
  it("reports, rather than silently swallows, a resolve arriving after the render returned", function()
    local stash = nil
    local seen = withDiagnostics(function()
      local res = resource.new()
      local Profile = function() return H.h("p", nil, res:get()) end
      local html = server.render_to_string(H.h(H.Suspense, {
        fallback = H.h("p", nil, "loading..."),
        onSuspend = function(r) stash = r end,
      }, H.h(Profile)))
      assert.equal(html, "<p>loading...</p>")

      -- The render has returned its string to the caller. Now resolve.
      local ok = pcall(function() stash:resolve("REAL") end)
      assert.truthy(ok)
    end)

    local diag = findDiagnostic(seen, "suspense.late_resolve")
    assert.is_not_nil(diag)
    -- Distinguished from the mid-pass case above.
    assert.truthy(diag.after_render)
    assert.truthy(diag.message:find("already returned", 1, true))
  end)

  -- REGRESSION (CRITICAL): a genuine render error after a deferred resume
  -- used to propagate out of Resource:resolve() at the resolver's own
  -- call site -- arbitrary application code, nowhere near the
  -- ErrorBoundary that should have handled it, and long after that
  -- boundary had returned. Resource:resolve is a plain data setter and
  -- must never throw a component's render error.
  it("never throws a render error out of Resource:resolve() at the resolver's call site", function()
    local stash = nil
    withDiagnostics(function()
      local res = resource.new()
      local Bad = function()
        local _ = res:get()
        error("boom after resume", 0)
      end
      local html = server.render_to_string(H.h(H.ErrorBoundary, {
        fallback = function(err) return H.h("p", nil, "caught: " .. tostring(err.message)) end,
      }, H.h(H.Suspense, {
        fallback = H.h("p", nil, "loading..."),
        onSuspend = function(r) stash = r end,
      }, H.h(Bad))))
      assert.equal(html, "<p>loading...</p>")

      local ok, err = pcall(function() stash:resolve("x") end)
      assert.truthy(ok, "resolve() must not raise the subtree's render error: " .. tostring(err))
    end)
  end)

  -- The ErrorBoundary reachability that IS preserved: a boundary inside
  -- the Suspense subtree sits on the coroutine's own frozen stack, so it
  -- still catches a render error raised after a synchronous resume.
  it("an ErrorBoundary inside the Suspense subtree still catches an error raised after a resume", function()
    local res = resource.new()
    local Bad = function()
      local _ = res:get()
      error("boom after resume", 0)
    end
    local html = server.render_to_string(H.h(H.Suspense, {
      fallback = H.h("p", nil, "loading..."),
      onSuspend = function(r) r:resolve("ok") end,
    }, H.h(H.ErrorBoundary, {
      fallback = function(err) return H.h("p", nil, "caught: " .. tostring(err.message)) end,
    }, H.h(Bad))))
    assert.truthy(html:find("caught: boom after resume", 1, true))
  end)

  -- REGRESSION (HIGH): coroutine.isyieldable() is true inside ANY
  -- coroutine, not only a Suspense-driven one. Resource:get() therefore
  -- yielded the suspension straight past a resumable pcall to a driver
  -- that had no idea what it was, leaving the coroutine suspended forever
  -- with no diagnostic -- turning v1's catchable error into a silent
  -- permanent hang for any coroutine-hosted renderer.
  it("raises a catchable suspension inside a coroutine no Suspense boundary is driving", function()
    local res = resource.new()
    local co = coroutine.create(function()
      local ok, err = pcall(function() return res:get() end)
      return ok, err
    end)

    local resumed, ok, err = coroutine.resume(co)
    assert.truthy(resumed)
    -- The coroutine ran to completion rather than being left suspended.
    assert.equal(coroutine.status(co), "dead")
    -- pcall caught it, exactly as in v1.
    assert.falsy(ok)
    assert.truthy(resource.isSuspension(err))
  end)

  it("only yields inside a coroutine explicitly marked as Suspense-driven", function()
    local res = resource.new()
    local co = coroutine.create(function() return res:get() end)
    resource.markDriven(co)
    assert.truthy(resource.isDriven(co))

    local resumed, yielded = coroutine.resume(co)
    assert.truthy(resumed)
    -- Marked: it suspends by yielding, and stays resumable.
    assert.equal(coroutine.status(co), "suspended")
    assert.truthy(resource.isSuspension(yielded))

    resource.unmarkDriven(co)
    assert.falsy(resource.isDriven(co))
  end)

  -- REGRESSION (MEDIUM): settle() cleared _waiters before iterating and
  -- called each waiter unprotected, so the first waiter to throw both
  -- escaped resolve() AND stranded every later waiter -- they had already
  -- been detached from the list and were unreachable forever.
  it("runs every waiter even when an earlier one throws, and contains the error", function()
    local ran_second = false
    local seen = withDiagnostics(function()
      local res = resource.new()
      res:_addWaiter(function() error("waiter exploded", 0) end)
      res:_addWaiter(function() ran_second = true end)

      local ok = pcall(function() res:resolve("value") end)
      -- The failure did not escape the data setter...
      assert.truthy(ok)
      -- ...and the resource still settled correctly.
      assert.equal(res:status(), "ready")
    end)

    -- ...and the sibling waiter still ran.
    assert.truthy(ran_second)
    assert.is_not_nil(findDiagnostic(seen, "suspense.waiter_error"))
  end)
end)
