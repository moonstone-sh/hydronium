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

  local hosts = require("hydronium.runtime.hosts")

  it("decodes browser JSON and returns its cancellation handle", function()
    local complete, cancelled, seen
    local _, release = hosts.install("router.http", 1, { get = function(path, done)
      assert.equal(path, "/api/packages/ballad")
      complete = done
      return function() cancelled = true end
    end })
    local ok, err = pcall(function()
      local cancel = http.get({}, "registry", "/api/packages/ballad", function(response) seen = response end)
      complete('{"status":200,"body":{"coordinate":"moonstone/ballad"}}')
      assert.equal(seen.body.coordinate, "moonstone/ballad")
      cancel()
      assert.truthy(cancelled)
    end)
    release()
    assert.truthy(ok, tostring(err))
  end)

  it("reports bridge failures rather than accepting a status-zero response", function()
    local _, release = hosts.install("router.http", 1, { get = function(_, done)
      done('{"status":0,"error":"network unavailable"}')
    end })
    local failure
    local ok, err = pcall(http.get, {}, "registry", "/api/packages/ballad", function(_, e) failure = e end)
    release()
    assert.truthy(ok, tostring(err))
    assert.equal(failure, "network unavailable")
  end)

  it("ignores the removed __router_http_get global", function()
    _G.__router_http_get = function() error("must not be called") end
    local ok, err = pcall(http.get, {}, "registry", "/api/x", function() end)
    _G.__router_http_get = nil
    assert.falsy(ok)
    assert.truthy(tostring(err):find("createHttpCapability", 1, true), tostring(err))
  end)
end)
