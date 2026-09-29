local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local H, R = require("hydronium"), require("hydronium_router")
local function make(root, components, opts)
  opts = opts or {}
  local site = R.createSite({ root = R.node(root) })
  return site:createRouter({ history = R.createMemoryHistory({ initial = opts.initial or "/one/1" }),
    resolve = function(id) return components[id] end, resolve_loader = opts.resolve_loader, target = opts.target or "dom",
    hydration = opts.hydration }), site
end
local function fixture()
  return { id = "root", path = "/", screen = "Layout", children = {
    { id = "one", path = "one/:id", screen = "Page", slots = { sidebar = "Sidebar", toolbar = "Toolbar" }, load = "Load" },
    { id = "two", path = "two", screen = "Other" },
  } }
end
describe("Router named slots", function()
  it("renders direct default/named outlets and shares params and one loader", function()
    local calls, mounts = 0, 0
    local components = {
      Layout = function() mounts = mounts + 1; return function() return H.h("main", nil,
        H.h(R.Outlet), H.h(R.Outlet, { name = "sidebar" }), H.h(R.Outlet, { name = "toolbar" })) end end,
      Page = function() local params = R.useParams(); return function() return H.h("p", nil, "page:" .. params.id) end end,
      Sidebar = function() local data = R.useRouteData(); return function() return H.h(H.Fragment, nil, H.h("aside", nil, "side:" .. data:value().id), H.h("span", nil, "extra")) end end,
      Toolbar = function(props) return H.h("header", nil, "tool:" .. props.route.id) end,
      Other = function() return H.h("p", nil, "other") end,
    }
    local router = make(fixture(), components, { resolve_loader = function() return function(ctx) calls = calls + 1; return { id = ctx.params.id } end end })
    local view = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(view:text(), "page:1side:1extratool:one")
    assert.equal(calls, 1)
    router.navigate("/one/2")
    assert.equal(view:text(), "page:2side:2extratool:one")
    assert.equal(calls, 2)
    assert.equal(mounts, 1)
    router.navigate("/two")
    assert.equal(view:text(), "other")
    router.navigate("/one/3"); assert.equal(view:text(), "page:3side:3extratool:one")
    view:unmount()
  end)

  it("passes named child outlets and composes nested slots through pathless nodes", function()
    local root = { id = "root", path = "/", screen = "Layout", children = {
      { id = "group", slots = { sidebar = "SideLayout" }, children = {
        { id = "bridge", children = { { id = "page", path = "", screen = "Page", slots = { sidebar = "SideLeaf" } } } },
      } },
    } }
    local router = make(root, {
      Layout = function() return function(props) return H.h("main", nil, props.outlet, props.outlets.sidebar) end end,
      SideLayout = function() return function(props) return H.h("aside", nil, "outer:", props.outlet) end end,
      SideLeaf = function(props) return H.h("span", nil, "inner:" .. props.slot) end,
      Page = function() return H.h("p", nil, "main") end,
    }, { initial = "/" })
    local view = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(view:text(), "mainouter:inner:sidebar")
    view:unmount()
  end)

  it("supports target maps, slots-only leaves, explicit fallbacks and serializable manifests", function()
    local root = { id = "root", path = "/", screen = "Layout", children = {
      { id = "page", path = "", slots = { sidebar = { dom = "DomSide", ink = "InkSide" } } },
    } }
    local router, site = make(root, {
      Layout = function() return H.h("main", nil, H.h(R.Outlet, { name = "sidebar" }), H.h(R.Outlet, { name = "absent", fallback = function() return H.h("p", nil, "fallback") end })) end,
      DomSide = function() return H.h("p", nil, "DOM") end, InkSide = function() return H.h("p", nil, "INK") end,
    }, { initial = "/" })
    local view = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(view:text(), "DOMfallback")
    assert.same(site:manifest().root.children[1].slots, root.children[1].slots)
    assert.equal(#site:endpoints(), 1)
    view:unmount()
    assert.has_error(function() R.node({ id = "invalid", slots = { default = "Page" } }) end, "reserved")
    assert.has_error(function() R.node({ id = "invalid", slots = { sidebar = function() end } }) end, "logical id")
  end)

  it("isolates slot identity and follows own-param remount and reuse policies", function()
    local mounts = 0
    local function Shared() mounts = mounts + 1; local value = mounts; return function() return H.h("span", nil, tostring(value)) end end
    local root = { id = "root", path = "/", screen = "Layout", children = {
      { id = "page", path = "one/:id", screen = "Shared", slots = { sidebar = "Shared" } },
    } }
    local router = make(root, { Layout = function() return function(props) return H.h("main", nil, props.outlet, props.outlets.sidebar) end end, Shared = Shared })
    local view = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(mounts, 2)
    router.navigate("/one/2"); assert.equal(mounts, 4)
    view:unmount()
    root.children[1].reuse = "keep"; mounts = 0
    router = make(root, { Layout = function() return function(props) return H.h("main", nil, props.outlet, props.outlets.sidebar) end end, Shared = Shared })
    view = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    router.navigate("/one/2"); assert.equal(mounts, 2)
    view:unmount()
  end)

  it("shares pending/error UI and hydrates data without executing a second loader", function()
    local finish, calls = nil, 0
    local root = { id = "root", path = "/", screen = "Layout", children = {
      { id = "page", path = "", screen = "Page", slots = { sidebar = "Side" }, load = "Load", pending = "Pending", error = "Error" },
    } }
    local components = {
      Layout = function() return function(props) return H.h("main", nil, props.outlet, props.outlets.sidebar) end end,
      Page = function() local data = R.useRouteData(); return function() return H.h("p", nil, "page:" .. (data:ready() and data:value().label or "")) end end,
      Side = function() local data = R.useRouteData(); return function() return H.h("p", nil, "side:" .. (data:ready() and data:value().label or "")) end end,
      Pending = function() return H.h("p", nil, "pending") end, Error = function(props) return H.h("p", nil, "error:" .. props.error.message) end,
    }
    local router = make(root, components, { initial = "/", resolve_loader = function() return function(_, done) calls = calls + 1; finish = done; return function() end end end })
    local view = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(view:text(), "pendingpending"); assert.equal(calls, 1)
    finish({ label = "ready" }); assert.equal(view:text(), "page:readyside:ready")
    router.revalidate(); finish(nil, R.routeError(404, "missing")); assert.equal(view:text(), "error:missingerror:missing")
    view:unmount()
    calls = 0
    router = make(root, components, { initial = "/", hydration = R.state.encode({ version = 1, canonical_url = "/", route_id = "page", route_chain = { "root", "page" }, params = {},
      resources = { page = { status = "ready", value = { label = "SSR" } } } }), resolve_loader = function() return function() calls = calls + 1 end end })
    local html = require("hydronium_dom.server").renderToString(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.truthy(html:find("page:SSR", 1, true)); assert.truthy(html:find("side:SSR", 1, true)); assert.equal(calls, 0)
  end)
end)
