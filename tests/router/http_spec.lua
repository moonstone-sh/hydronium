local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local http = require("hydronium_router.http")

describe("Router: HTTP loader transport", function()
  it("uses a named Meteorite capability synchronously during SSR", function()
    local seen
    local ctx = { request = {
      http = function(_, name)
        assert.equal(name, "registry")
        return { get = function(_, path)
          assert.equal(path, "/api/packages/moonstone/ballad")
          return { status = 200, body = { coordinate = "moonstone/ballad" } }
        end }
      end,
    } }
    http.get(ctx, "registry", "/api/packages/moonstone/ballad", function(response) seen = response end)
    assert.equal(seen.body.coordinate, "moonstone/ballad")
  end)

  it("decodes browser JSON and returns its cancellation handle", function()
    local previous = _G.__router_http_get
    local complete, cancelled, seen
    _G.__router_http_get = function(path, done)
      assert.equal(path, "/api/packages/ballad")
      complete = done
      return function() cancelled = true end
    end
    local cancel = http.get({}, "registry", "/api/packages/ballad", function(response) seen = response end)
    complete('{"status":200,"body":{"coordinate":"moonstone/ballad"}}')
    assert.equal(seen.body.coordinate, "moonstone/ballad")
    cancel()
    assert.truthy(cancelled)
    _G.__router_http_get = previous
  end)

  it("reports bridge failures rather than accepting a status-zero response", function()
    local previous = _G.__router_http_get
    _G.__router_http_get = function(_, done)
      done('{"status":0,"error":"network unavailable"}')
    end
    local failure
    http.get({}, "registry", "/api/packages/ballad", function(_, err) failure = err end)
    assert.equal(failure, "network unavailable")
    _G.__router_http_get = previous
  end)
end)
