local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local H = require("hydronium")

local schema = {
  ["~standard"] = {
    validate = function(values)
      if values.name == "" then
        return { issues = { { path = { { key = "name" } }, message = "Required" } } }
      end
      return { value = { name = values.name, normalized = true } }
    end,
  },
}

describe("Core: actions and scoped forms", function()
  it("defines transportable actions and produces Meteorite canonical specs", function()
    local action = H.action({ id = "packages.create", method = "POST", path = "/users/:user/packages/:tail*", schema = schema })
    assert.equal(action:path_for({ user = "sad pepe", tail = "one/two" }), "/users/sad%20pepe/packages/one/two")
    local spec = action:meteorite({ handler = { kind = "lua", module = "actions.create" } })
    assert.equal(spec.id, "packages.create")
    assert.equal(spec.route, "/users/:user/packages/:tail*")
    assert.equal(spec.handler.module, "actions.create")
    assert.has_error(function() action.path = "/other" end, "cannot modify action")
    local ok, _, output = action:check({ name = "ok" })
    assert.truthy(ok)
    assert.truthy(output.normalized)
  end)

  it("does not retain cancellation after a synchronous transport completion", function()
    local action = H.action({ id = "settings.save", path = "/settings" })
    local cancelled = false
    local form, owner = H.createScope(function()
      return H.useForm(action, {
        transport = function(_, done)
          done(200, { data = "saved" })
          return function() cancelled = true end
        end,
      })
    end)
    assert.truthy(form:submit())
    assert.falsy(form:pending())
    assert.equal(form:data(), "saved")
    owner:dispose()
    assert.falsy(cancelled)
  end)

  it("uses local signals, rejects stale completions, and cancels on scope disposal", function()
    local action = H.action({ id = "packages.create", method = "POST", path = "/packages", schema = schema })
    local done, cancelled
    local form, scope = H.createScope(function()
      return H.useForm(action, {
        initial = { values = { name = "" } },
        transport = function(_, callback)
          done = callback
          return function() cancelled = true end
        end,
      })
    end)
    assert.falsy(form:submit())
    assert.equal(form:error("name"), "Required")
    form:set_value("name", "first")
    assert.truthy(form:submit())
    assert.truthy(form:pending())
    assert.falsy(form:submit({ name = "second" }))
    form:reset()
    assert.falsy(done(200, { values = { name = "stale" } }))
    assert.equal(form:values().name, nil)
    form:set_value("name", "fresh")
    assert.truthy(form:submit())
    done(201, { values = { name = "server" }, data = { id = 1 } })
    assert.equal(form:values().name, "server")
    assert.equal(form:data().id, 1)
    scope:dispose()
    assert.truthy(cancelled)
  end)

  it("keeps separate instances for the same action", function()
    local action = H.action({ id = "packages.create", method = "POST", path = "/packages" })
    local one = H.useForm(action, { initial = { values = { name = "one" } } })
    local two = H.useForm(action, { initial = { values = { name = "two" } } })
    one:set_value("name", "changed")
    assert.equal(one:values().name, "changed")
    assert.equal(two:values().name, "two")
  end)

  it("enhances native form props through optional browser globals", function()
    local previous_values = _G.__hydronium_form_values
    local previous_request = _G.__hydronium_form_request
    local previous_redirect = _G.__hydronium_form_redirect
    local sent, redirected
    _G.__hydronium_form_values = function() return '{ name = "Ada" }' end
    _G.__hydronium_form_request = function(url, method, body, id, done)
      sent = { url, method, body, id }
      done(201, '{ ok = true, data = { id = 7 }, redirect = "/done" }')
    end
    _G.__hydronium_form_redirect = function(url) redirected = url end
    local form = H.useForm(H.action({ id = "users.create", path = "/users" }))
    assert.equal(type(form.props.onSubmit), "function")
    form.props.onSubmit('{ name = "Ada" }')
    assert.equal(sent[3], "name=Ada")
    assert.equal(form:data().id, 7)
    assert.equal(redirected, "/done")
    _G.__hydronium_form_values = previous_values
    _G.__hydronium_form_request = previous_request
    _G.__hydronium_form_redirect = previous_redirect
  end)
end)
