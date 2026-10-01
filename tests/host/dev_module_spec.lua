local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local watch = require("hydronium_dom.dev.watch")
local handler = require("hydronium_dom.server.meteorite_routes.dev_module")

describe("Hydronium dev module revision header", function()
  it("stays below Meteorite's 1 KiB limit with 200 watched modules", function()
    local files = {}
    local prefix = os.tmpname()
    for index = 1, 200 do
      local path = string.format("%s-%03d.lua", prefix, index)
      local file = io.open(path, "w")
      assert.truthy(file)
      file:write("return ", index, "\n")
      file:close()
      files[index] = path
    end

    local registry = {
      module = function(_, id)
        if id == "views.App" then
          return { target = "client", transform = "lua", path = files[1] }
        end
      end,
    }
    local routes_key = "hydronium_dom.server.meteorite_routes"
    local previous_routes = package.loaded[routes_key]
    package.loaded[routes_key] = {
      registry = function() return registry end,
      watch_files = function() return files end,
    }

    local context = {
      param = function() return "views.App" end,
      query = function() return nil end,
      text = function(_, status, body, options)
        return { status = status, body = body, headers = options and options.headers or {} }
      end,
    }
    local expected_revision = watch.snapshot(files).revision
    local runner_assert = _G.assert
    _G.assert = function(value, message)
      if not value then error(message or "assertion failed", 2) end
      return value
    end
    local ok, response = pcall(handler, context)
    _G.assert = runner_assert
    package.loaded[routes_key] = previous_routes
    for _, path in ipairs(files) do os.remove(path) end
    os.remove(prefix)

    assert.truthy(ok, response)
    assert.equal(response.status, 200, response.body)
    assert.equal(response.body, "return 1\n")
    assert.truthy(#response.headers["X-Hydronium-Revision"] <= 1024)
    assert.equal(response.headers["X-Hydronium-Revision"], expected_revision)
  end)
end)
