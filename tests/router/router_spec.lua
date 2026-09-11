local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local H = require("hydronium")
local R = require("hydronium_router")

local function page(label)
  return function() return H.h("p", nil, label) end
end

describe("Router: reactive public API", function()
  it("matches, navigates, exposes params, query and typed hrefs", function()
    local history = R.createMemoryHistory({ initial = "/users/1?tab=profile" })
    local router = R.createRouter({
      history = history,
      routes = {
        R.route("home", "/", page("home")),
        R.route("users.show", "/users/:id", page("user")),
      },
    })

    assert.equal(router.match().id, "users.show")
    assert.equal(router.params.id, "1")
    assert.equal(router.search_params.tab, "profile")
    assert.equal(router.href("users.show", { id = 9 }), "/users/9")

    router.navigate("/users/2?tab=activity")
    assert.equal(router.params.id, "2")
    assert.equal(router.search_params.tab, "activity")
    assert.equal(router.location().path, "/users/2")
  end)

  it("renders Outlet and hook consumers under the router Provider", function()
    local router = R.createRouter({
      history = R.createMemoryHistory({ initial = "/users/7" }),
      routes = { R.route("users.show", "/users/:id", function()
        local params = R.useParams()
        return function() return H.h("p", nil, "user " .. params.id) end
      end) },
    })

    local root = H.create_test_root()
    root:render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(root:text(), "user 7")
    router.navigate("/users/8")
    assert.equal(root:text(), "user 8")
  end)

  it("renders a notFound component", function()
    local router = R.createRouter({ history = R.createMemoryHistory({ initial = "/missing" }), routes = {} })
    local root = H.create_test_root()
    root:render(H.h(router.Provider, nil, H.h(R.Outlet, {
      notFound = function(props) return H.h("p", nil, "missing " .. props.location.path) end,
    })))
    assert.equal(root:text(), "missing /missing")
  end)

  it("preserves a matched page's state when its module is hot-replaced", function()
    local family = require("hydronium.core.family")
    local family_loader = require("hydronium.core.family_loader")
    local hmr = require("hydronium.core.hmr")
    local module_id = "scratch.router_hmr_page"

    package.loaded[module_id] = nil
    package.preload[module_id] = nil
    family_loader.reset()
    family.reset()
    family_loader.enable()

    hmr.install(module_id, [[
      local H = require("hydronium")
      return function(_, scope)
        local count, set_count = scope.refresh_registry:signal(1, {
          kind = "signal", name = "count", block_path = "router.page.setup",
        })
        _G.__router_hmr_set = set_count
        return function() return H.h("p", nil, "old " .. count()) end
      end
    ]])
    local Page = require(module_id)
    local router = R.createRouter({
      history = R.createMemoryHistory({ initial = "/page" }),
      routes = { R.route("page", "/page", Page) },
    })
    local root = H.create_test_root()
    root:render(H.h(router.Provider, nil, H.h(R.Outlet)))
    _G.__router_hmr_set(9)
    assert.equal(root:text(), "old 9")

    local result = hmr.replace(module_id, [[
      local H = require("hydronium")
      return function(_, scope)
        local count, set_count = scope.refresh_registry:signal(1, {
          kind = "signal", name = "count", block_path = "router.page.setup",
        })
        _G.__router_hmr_set = set_count
        return function() return H.h("p", nil, "new " .. count()) end
      end
    ]])
    assert.equal(result.failed, 0)
    assert.equal(root:text(), "new 9")

    root:unmount()
    _G.__router_hmr_set = nil
    package.loaded[module_id] = nil
    package.preload[module_id] = nil
    family_loader.reset()
    family.reset()
  end)
end)
