-- create_router with a FLAT `routes` table -- i.e. resolved route
-- declarations passed directly, without going through site().
--
-- This path rendered NOTHING, silently, and no spec covered it: every other
-- router spec builds its routes with R.createSite(), which records a
-- `meta.chain`. Without that chain, match_chain fell back to the matcher's
-- internal record, Outlet read `node.component` off it (the component lives
-- on the caller's declaration, not the record), got nil, and
-- render_component returns nil for nil WITHOUT erroring. Meanwhile
-- router.match().id still reported the correct route, so from the outside
-- everything looked right and the page was simply blank.
--
-- Found while building the SPA demo for docs/HYDRONIUM_SPA_MODE_PLAN.md.

local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local H = require("hydronium")
local R = require("hydronium_router")

local function flat_router(initial)
  return R.createRouter({
    history = R.createMemoryHistory({ initial = initial or "/" }),
    routes = {
      { id = "home", path = "/", component = function() return H.h("p", nil, "home screen") end },
      { id = "second", path = "/second", component = function() return H.h("p", nil, "second screen") end },
      { id = "user", path = "/user/:name", component = function() return H.h("p", nil, "user screen") end },
    },
  })
end

describe("create_router with flat routes (no site())", function()
  it("renders the matched route's component", function()
    local router = flat_router("/")
    local rendered = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(rendered:text(), "home screen")
  end)

  it("renders a different route after navigation", function()
    local router = flat_router("/")
    local rendered = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(rendered:text(), "home screen")
    router.navigate("/second")
    assert.equal(rendered:text(), "second screen")
  end)

  it("matches a parameterised route and exposes its params", function()
    local router = flat_router("/user/ada")
    local rendered = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(rendered:text(), "user screen")
    -- Params ride on the router, not on component props (see Outlet: it
    -- passes { key, route, outlet } only).
    assert.equal(router.params.name, "ada")
  end)

  it("still reports the matched id -- the symptom that made this silent", function()
    -- match() was ALWAYS correct here; only rendering was empty. Pinning it
    -- keeps the regression honest: a future break must not be able to hide
    -- behind a correct-looking match.
    local router = flat_router("/second")
    assert.equal(router.match().id, "second")
  end)

  it("does not disturb the site()-built path", function()
    -- site() nodes must be serializable, so screens are NAMED here and
    -- resolved by id -- the opposite of the flat shape above. Both must work.
    local site = R.createSite({ root = R.node({ id = "root", path = "/", screen = "Root" }) })
    local router = site:createRouter({
      history = R.createMemoryHistory({ initial = "/" }),
      resolve = function(id) return ({ Root = function() return H.h("p", nil, "root screen") end })[id] end,
    })
    local rendered = H.test.render(H.h(router.Provider, nil, H.h(R.Outlet)))
    assert.equal(rendered:text(), "root screen")
  end)
end)
