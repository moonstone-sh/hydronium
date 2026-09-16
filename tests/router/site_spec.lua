local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local H = require("hydronium")
local R = require("hydronium_router")

local function site_fixture()
  return R.createSite({
    root = R.node({
      id = "root",
      path = "/",
      screen = "views.Root",
      children = {
        R.node({ id = "home", path = "", screen = "views.Home" }),
        R.node({
          id = "package",
          path = "packages/:namespace/:package",
          screen = "views.PackageLayout",
          load = "loaders.package",
          actions = {
            star = { ref = "actions.star", path = "/actions/packages/:namespace/:package/star" },
          },
          children = {
            R.node({ id = "package.readme", path = "", screen = "views.PackageReadme" }),
            R.node({ id = "package.manifest", path = "manifest", screen = "views.PackageManifest" }),
          },
        }),
      },
    }),
  })
end

describe("Router: serializable route trees", function()
  it("composes relative paths and exposes only leaf endpoints", function()
    local site = site_fixture()
    local endpoints = site:endpoints()
    assert.equal(#endpoints, 3)
    assert.equal(endpoints[1].path, "/")
    assert.equal(endpoints[2].path, "/packages/:namespace/:package")
    assert.equal(endpoints[3].path, "/packages/:namespace/:package/manifest")
    assert.equal(site:get("package").full_path, "/packages/:namespace/:package")
    assert.equal(site:get("package").load.ref, "loaders.package")
    local actions = site:action_endpoints()
    assert.equal(#actions, 1)
    assert.equal(actions[1].id, "package.star")
    assert.equal(actions[1].method, "POST")
  end)

  it("resolves logical screens only when a host creates the router", function()
    local resolved = {}
    local router = site_fixture():createRouter({
      history = R.createMemoryHistory({ initial = "/packages/moonstone/ballad" }),
      resolve = function(id, kind)
        resolved[#resolved + 1] = kind .. ":" .. id
        return function(props)
          if id == "views.Root" or id == "views.PackageLayout" then return props.outlet end
          return H.h("p", nil, id)
        end
      end,
      resolve_loader = function()
        return function(ctx) return { coordinate = ctx.params.namespace .. "/" .. ctx.params.package } end
      end,
    })
    assert.equal(router.match().id, "package.readme")
    assert.equal(router.route_at(2).id, "package")
    assert.equal(router.params.namespace, "moonstone")
    assert.equal(router.route_data("package"):value().coordinate, "moonstone/ballad")
    assert.truthy(#resolved >= 5)
  end)

  it("renders nested outlets when created during component setup", function()
    local site = site_fixture()
    local function App()
      local router = site:createRouter({
        history = R.createMemoryHistory({ initial = "/" }),
        resolve = function(id)
          if id == "views.Root" then return function(props) return H.h("main", nil, props.outlet) end end
          return function() return H.h("p", nil, id) end
        end,
        resolve_loader = function() return function() return {} end end,
      })
      return H.h(router.Provider, nil, H.h(R.Outlet))
    end
    local rendered = H.test.render(H.h(App))
    assert.equal(rendered:text(), "views.Home")
  end)

  it("selects host-specific screens without changing the route tree", function()
    local site = R.createSite({ root = R.node({ id = "root", path = "/", children = {
      R.node({ id = "home", path = "", screen = {
        dom = "views.dom.Home",
        ink = "views.ink.Home",
      } }),
    } }) })
    local routes = site:routes(function(id) return id end, "ink")
    assert.equal(routes[1].component, "views.ink.Home")
    assert.equal(site:manifest().root.children[1].screen.dom, "views.dom.Home")
  end)

  it("exports only explicit literal loader-free paths", function()
    local site = R.createSite({ root = R.node({ id = "root", children = {
      R.node({ id = "about", path = "about", screen = "About", prerender = true }),
      R.node({ id = "home", path = "", screen = "Home", prerender = true }),
      R.node({ id = "private", path = "private", screen = "Private" }),
      R.node({ id = "dynamic", path = "users/:id", screen = "User" }),
    } }) })
    local paths = site:prerender_paths()
    assert.equal(#paths, 2)
    assert.equal(paths[1], "/")
    assert.equal(paths[2], "/about")
    assert.equal(site:manifest().root.children[1].prerender, true)

    assert.has_error(function()
      R.createSite({ root = R.node({ id = "root", children = {
        R.node({ id = "dynamic", path = "users/:id", screen = "User", prerender = true }),
      } }) })
    end, "needs a literal path")
    assert.has_error(function()
      R.createSite({ root = R.node({ id = "root", load = "loaders.root", children = {
        R.node({ id = "home", path = "", screen = "Home", prerender = true }),
      } }) })
    end, "cannot use a loader")
  end)

  it("rejects ambiguous and non-canonical trees", function()
    assert.has_error(function()
      R.createSite({ root = R.node({ id = "root", children = {
        R.node({ id = "one", path = "users/:id", screen = "One" }),
        R.node({ id = "two", path = "users/:slug", screen = "Two" }),
      } }) })
    end, "same URL shape")
    assert.has_error(function()
      R.node({ id = "bad", path = "bad", screen = "Bad", guard = function() end })
    end, "serializable")
    assert.has_error(function()
      R.createSite({ root = R.node({ id = "root", children = {
        R.node({ id = "parent", path = ":id", screen = "Parent", children = {
          R.node({ id = "child", path = ":id", screen = "Child" }),
        } }),
      } }) })
    end, "duplicate path param")
    assert.has_error(function()
      R.createSite({ root = R.node({ id = "root", children = {
        R.node({ id = "wild", path = "files/:path*", screen = "Files", children = {
          R.node({ id = "after", path = "edit", screen = "Edit" }),
        } }),
      } }) })
    end, "may not have children")
    assert.has_error(function()
      R.createSite({ root = R.node({ id = "root", children = {
        R.node({ id = "bad", path = "/absolute", screen = "Bad" }),
      } }) })
    end, "must be relative")
  end)
end)
