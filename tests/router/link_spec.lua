local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local H = require("hydronium")
local R = require("hydronium_router")

local function app(initial, base)
  local components = {
    Root = function(props) return props.outlet end,
    Home = function()
      return H.h("nav", nil,
        H.h(R.Link, { to = "/", class = "nav" }, "Home"),
        H.h(R.Link, { route = "post", params = { id = 7 }, query = { tab = "comments" } }, "Post 7"),
        H.h(R.Link, { to = "/about", replace = true }, "About"))
    end,
    Post = function() return H.h("p", nil, "post") end,
    About = function() return H.h("p", nil, "about") end,
  }
  local site = R.createSite({ root = R.node({ id = "root", path = "/", screen = "Root", children = {
    { id = "home", path = "", screen = "Home" },
    { id = "post", path = "posts/:id", screen = "Post" },
    { id = "about", path = "about", screen = "About" },
  } }) })
  local history = R.createMemoryHistory({ initial = initial })
  local router = site:createRouter({ history = history, base = base, resolve = function(id) return components[id] end })
  local root = H.create_test_root()
  root:render(H.h(router.Provider, nil, H.h(R.Outlet)))
  return root, router, history
end

describe("Router: Link", function()
  it("renders real hrefs for paths and route ids, and marks the current page", function()
    local root = app("/")
    local links = root:findAllByType("a")
    assert.equal(#links, 3)
    assert.equal(links[1].props.href, "/")
    assert.equal(links[1].props.class, "nav")
    assert.equal(links[1].props["aria-current"], "page")
    assert.equal(links[2].props.href, "/posts/7?tab=comments")
    assert.equal(links[2].props["aria-current"], nil)
    assert.equal(links[3].props.href, "/about")
    assert.equal(links[1].props.to, nil, "router props do not reach the <a>")
  end)

  it("navigates through the router on the guarded navigate event", function()
    local root, router = app("/")
    local links = root:findAllByType("a")
    H.act(function() links[2].props.onNavigate() end)
    assert.equal(router.match().id, "post")
    assert.equal(router.params.id, "7")
    assert.equal(router.search_params.tab, "comments")
  end)

  it("prefixes the router's base in hrefs but navigates by app path", function()
    local root, router = app("/app/", "/app")
    local links = root:findAllByType("a")
    assert.equal(links[2].props.href, "/app/posts/7?tab=comments")
    H.act(function() links[3].props.onNavigate() end)
    assert.equal(router.match().id, "about")
  end)
end)
