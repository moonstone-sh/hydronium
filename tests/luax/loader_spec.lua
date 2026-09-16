local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local loader = require("hydronium_luax.loader")

local function write(path, source)
  local file = io.open(path, "w")
  if not file then error("could not open loader fixture", 0) end
  file:write(source)
  file:close()
end

describe("Hydronium LUAX loader", function()
  it("invalidates by content without spawning stat", function()
    local path = os.tmpname() .. ".luax"
    local old_popen = io.popen
    local ok, err = pcall(function()
      io.popen = function()
        error("loader must not spawn a subprocess", 0)
      end
      write(path, "return 1\n")
      local first = loader.source(path)
      write(path, "return 2\n") -- same byte length, possibly the same mtime tick
      local second = loader.source(path)
      assert.not_equal(second, first)
    end)
    io.popen = old_popen
    loader.invalidate(path)
    os.remove(path)
    assert.truthy(ok, err)
  end)
end)
