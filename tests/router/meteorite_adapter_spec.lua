local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local R = require("hydronium_router")
local adapter = require("hydronium_router.meteorite")

local function fake_app()
  local app = { routes = {} }
  local function declare(self, method, spec)
    local row = { id = spec.id, raw_path = spec.route, method = method, handler = spec.handler }
    self.routes[#self.routes + 1] = row
    return row
  end
  function app:get(spec) return declare(self, "GET", spec) end
  function app:post(spec) return declare(self, "POST", spec) end
  function app:put(spec) return declare(self, "PUT", spec) end
  function app:patch(spec) return declare(self, "PATCH", spec) end
  function app:delete(spec) return declare(self, "DELETE", spec) end
  return app
end

describe("Router: Meteorite adapter", function()
  it("lowers leaf endpoints through public app:get declarations and validates the final list", function()
    local site = R.createSite({ root = R.node({ id = "root", path = "/", screen = "views.Root", children = {
      R.node({ id = "home", path = "", screen = "views.Home" }),
      R.node({ id = "users.show", path = "users/:id", screen = "views.User" }),
    } }) })
    local app = fake_app()
    app:get({ route = "/assets/:path*", handler = "asset" })
    local rows = adapter.mount(app, site, { handler = { kind = "lua", module = "app.page_handler" } })
    assert.equal(#rows, 2)
    assert.equal(rows[2].id, "users.show")
    assert.equal(rows[2].raw_path, "/users/:id")
    assert.truthy(adapter.validate_final(app, site))
  end)

  it("rejects collisions and verifies Meteorite/Hydronium route parity in a module handler", function()
    local site = R.createSite({ root = R.node({ id = "root", path = "/", children = {
      R.node({ id = "users.show", path = "users/:id", screen = "views.User" }),
    } }) })
    local app = fake_app()
    app:get({ id = "api.users", route = "/users/:id", handler = "api" })
    assert.has_error(function()
      adapter.mount(app, site, { handler = "page" })
    end, "already declared")

    local output = nil
    local handler = adapter.handler(site, {
      resolve = function() return function() end end,
      render = function(_, _, opts) output = opts; return { status = opts.status } end,
    })
    local result = handler({ target = function() return "/users/8?tab=posts" end, route_id = function() return "users.show" end })
    assert.equal(result.status, 200)
    assert.equal(output.state.hydronium_router.location.path, "/users/8")
    assert.equal(output.state.hydronium_router.route_id, "users.show")
    assert.equal(output.state.hydronium_router.route_chain[2], "users.show")
    assert.has_error(function()
      handler({ target = function() return "/users/8" end, route_id = function() return "other" end })
    end, "Meteorite selected route")
  end)

  it("lowers route-owned actions and serves enhanced and progressive outcomes", function()
    local site = R.createSite({ root = R.node({ id = "root", path = "/", children = {
      R.node({
        id = "packages.show",
        path = "packages/:namespace/:package",
        screen = "views.Package",
        actions = { star = { ref = "actions.star", path = "/actions/packages/:namespace/:package/star" } },
      }),
    } }) })
    local action_handler = adapter.action_handler(site, {
      resolve_action = function(ref)
        assert.equal(ref, "actions.star")
        return function(ctx)
          return { ok = true, status = 201, data = { package = ctx.values.package }, redirect = "/done" }
        end
      end,
    })
    local app = fake_app()
    local rows = adapter.mount(app, site, { handler = "page", action_handler = action_handler })
    assert.equal(#rows, 2)
    assert.equal(rows[2].method, "POST")
    assert.equal(rows[2].raw_path, "/actions/packages/:namespace/:package/star")
    assert.truthy(adapter.validate_final(app, site))

    local response
    local c = {
      route_id = function() return "packages.show.star" end,
      form_body = function() return { package = "ballad" } end,
      header = function() return "application/json" end,
      json = function(_, status, body) response = { status = status, body = body }; return response end,
    }
    local enhanced = action_handler(c)
    assert.equal(enhanced.status, 201)
    assert.equal(enhanced.body.data.package, "ballad")

    c.header = function() return "text/html" end
    c.redirect = function(_, status, location) return { status = status, location = location } end
    local progressive = action_handler(c)
    assert.equal(progressive.status, 303)
    assert.equal(progressive.location, "/done")
  end)

  it("returns escaped HTML for native validation failures and JSON for enhanced forms", function()
    local site = R.createSite({ root = R.node({ id = "root", path = "/", children = {
      R.node({ id = "home", path = "", screen = "views.Home", actions = {
        contact = { id = "contact.submit", ref = "actions.contact", path = "/actions/contact" },
      } }),
    } }) })
    local handler = adapter.action_handler(site, {
      resolve_action = function()
        return function() return { ok = false, status = 422, errors = { name = { "Bad <name>" } } } end
      end,
    })
    local c = {
      route_id = function() return "contact.submit" end,
      form_body = function() return { name = "<name>" } end,
      header = function() return "text/html" end,
      bytes = function(_, status, content_type, body)
        return { status = status, content_type = content_type, body = body }
      end,
      json = function(_, status, body) return { status = status, body = body } end,
    }
    local native = handler(c)
    assert.equal(native.status, 422)
    assert.equal(native.content_type, "text/html; charset=utf-8")
    assert.truthy(native.body:find("Bad &lt;name&gt;", 1, true))
    assert.falsy(native.body:find("Bad <name>", 1, true))
    c.header = function() return "application/json" end
    local enhanced = handler(c)
    assert.equal(enhanced.status, 422)
    assert.equal(enhanced.body.errors.name[1], "Bad <name>")
  end)
end)
