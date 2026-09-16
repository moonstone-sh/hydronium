local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local H = require("hydronium")
local R = require("hydronium_router")

local function router_for(root, initial, components, opts)
  opts = opts or {}
  local site = R.createSite({ root = R.node(root) })
  return site:createRouter({
    history = R.createMemoryHistory({ initial = initial }),
    resolve = function(id) return components[id] end,
    resolve_loader = opts.resolve_loader,
    execute = opts.execute,
    hydration = opts.hydration,
  }), site
end

describe("Router: nested reactive API", function()
  it("matches a chain and builds hrefs from composed endpoint paths", function()
    local components = {
      Root = function(props) return props.outlet end,
      User = function() return H.h("p", nil, "user") end,
      Home = function() return H.h("p", nil, "home") end,
    }
    local router = router_for({
      id = "root", path = "/", screen = "Root", children = {
        { id = "home", path = "", screen = "Home" },
        { id = "user", path = "users/:id", screen = "User" },
      },
    }, "/users/1?tab=profile", components)

    assert.equal(router.match().id, "user")
    assert.equal(router.route_at(1).id, "root")
    assert.equal(router.params.id, "1")
    assert.equal(router.search_params.tab, "profile")
    assert.equal(router.href("user", { id = 9 }), "/users/9")
    router.navigate("/users/2?tab=activity")
    assert.equal(router.params.id, "2")
    assert.equal(router.search_params.tab, "activity")
  end)

  it("keeps parent state while remounting a node whose own params change", function()
    local root_mounts, org_mounts, project_mounts = 0, 0, 0
    local components = {
      Root = function(props)
        root_mounts = root_mounts + 1
        local count = H.createSignal(0)
        return function(p) count(count() + 0); return p.outlet end
      end,
      Org = function(props)
        org_mounts = org_mounts + 1
        return function(p) return H.h("section", nil, p.outlet) end
      end,
      Project = function()
        project_mounts = project_mounts + 1
        local params = R.useParams()
        return function() return H.h("p", nil, params.org .. "/" .. params.project) end
      end,
    }
    local router = router_for({
      id = "root", path = "/", screen = "Root", children = {
        { id = "org", path = "orgs/:org", screen = "Org", children = {
          { id = "project", path = "projects/:project", screen = "Project" },
        } },
      },
    }, "/orgs/acme/projects/one", components)
    local rendered = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(rendered:text(), "acme/one")
    router.navigate("/orgs/acme/projects/two")
    assert.equal(rendered:text(), "acme/two")
    assert.equal(root_mounts, 1)
    assert.equal(org_mounts, 1)
    assert.equal(project_mounts, 2)
    router.navigate("/orgs/moonstone/projects/two")
    assert.equal(rendered:text(), "moonstone/two")
    assert.equal(org_mounts, 2)
  end)

  it("runs loaders sequentially and exposes route resources", function()
    local order = {}
    local components = {
      Root = function(props) return props.outlet end,
      Package = function()
        local root_data = R.useRouteData("root")
        local package_data = R.useRouteData()
        return function()
          return H.h("p", nil, root_data:value().session .. ":" .. package_data:value().coordinate)
        end
      end,
    }
    local router = router_for({
      id = "root", path = "/", screen = "Root", load = "load.root", children = {
        { id = "package", path = "packages/:namespace/:package", screen = "Package", load = "load.package" },
      },
    }, "/packages/moonstone/ballad", components, {
      resolve_loader = function(id)
        if id == "load.root" then return function() order[#order + 1] = id; return { session = "anon" } end end
        return function(ctx)
          order[#order + 1] = id
          assert.equal(ctx.parent("root").session, "anon")
          return { coordinate = ctx.params.namespace .. "/" .. ctx.params.package }
        end
      end,
    })
    assert.equal(table.concat(order, ","), "load.root,load.package")
    assert.equal(router.route_data("package"):status(), "ready")
    local rendered = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(rendered:text(), "anon:moonstone/ballad")
  end)

  it("renders a route error screen when its loader returns a 404", function()
    local components = {
      Root = function(props) return props.outlet end,
      Package = function() return H.h("p", nil, "package") end,
      Missing = function(props) return H.h("p", nil, tostring(props.error.status)) end,
    }
    local router = router_for({
      id = "root", path = "/", screen = "Root", children = {
        { id = "package", path = "packages/:name", screen = "Package", error = "Missing", load = "load.package" },
      },
    }, "/packages/missing", components, {
      resolve_loader = function() return function() return R.routeError(404, "not found") end end,
    })
    local rendered = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(rendered:text(), "404")
  end)

  it("ignores stale asynchronous loader results", function()
    local callbacks = {}
    local components = {
      Root = function(props) return props.outlet end,
      Page = function()
        local data = R.useRouteData()
        return function() return H.h("p", nil, tostring(data:value())) end
      end,
      Pending = function() return H.h("p", nil, "pending") end,
    }
    local router = router_for({
      id = "root", path = "/", screen = "Root", children = {
        { id = "page", path = "pages/:id", screen = "Page", pending = "Pending", load = "load.page" },
      },
    }, "/pages/one", components, {
      execute = function(_, ctx, done)
        callbacks[ctx.params.id] = done
        return function() end
      end,
    })
    local rendered = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(rendered:text(), "pending")
    router.navigate("/pages/two")
    callbacks.one("old")
    assert.equal(rendered:text(), "pending")
    callbacks.two("new")
    assert.equal(rendered:text(), "new")
  end)

  it("accepts callback loaders without a custom executor and cancels obsolete work", function()
    local callbacks, cancelled = {}, {}
    local router = router_for({
      id = "root", path = "/", screen = "Root", children = {
        { id = "page", path = "pages/:id", screen = "Page", load = "load.page" },
      },
    }, "/pages/one", { Root = function(props) return props.outlet end, Page = function() end }, {
      resolve_loader = function()
        return function(ctx, done)
          local id = ctx.params.id
          callbacks[id] = done
          return function() cancelled[id] = true end
        end
      end,
    })
    assert.truthy(router.route_data("page"):pending())
    router.navigate("/pages/two")
    assert.truthy(cancelled.one)
    callbacks.one({ name = "stale" })
    callbacks.two({ name = "current" })
    assert.equal(router.route_data("page"):value().name, "current")
  end)

  it("surfaces loader redirects without treating data tables as control results", function()
    local components = { Root = function(props) return props.outlet end, Page = function() return H.h("p", nil, "page") end }
    local router = router_for({
      id = "root", path = "/", screen = "Root", children = {
        { id = "page", path = "private", screen = "Page", load = "load.private" },
        { id = "signin", path = "signin", screen = "Page" },
      },
    }, "/private", components, {
      resolve_loader = function() return function() return R.redirect("/signin") end end,
    })
    assert.equal(router.redirect().to, "/signin")
  end)

  it("hydrates matching loader resources without rerunning the server work", function()
    local executions = 0
    local components = { Root = function(props) return props.outlet end, Page = function() return H.h("p", nil, "page") end }
    local router = router_for({
      id = "root", path = "/", screen = "Root", children = {
        { id = "page", path = "pages/:id", screen = "Page", load = "load.page" },
      },
    }, "/pages/one", components, {
      execute = function() executions = executions + 1 end,
      hydration = R.state.encode({
        version = 1,
        canonical_url = "/pages/one",
        route_id = "page",
        route_chain = { "root", "page" },
        params = { id = "one" },
        resources = { page = { status = "ready", value = { name = "One" } } },
      }),
    })
    assert.equal(executions, 0)
    assert.equal(router.route_data("page"):value().name, "One")
  end)
end)
