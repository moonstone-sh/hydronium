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

describe("automatic LUAX require", function()
  it("registers once and loads a module without a Lua shim", function()
    local prefix = os.tmpname()
    local path = prefix .. "_automatic_luax_fixture.luax"
    local old_path = package.path
    local id = "automatic_luax_fixture"
    local ok, err = pcall(function()
      write(path, "return { value = 42 }\n")
      package.path = prefix .. "_?.lua;" .. old_path
      assert.equal(loader.install(), loader.install())
      assert.equal(require(id).value, 42)
      assert.equal(require(id), package.loaded[id])
    end)
    package.path = old_path; package.loaded[id] = nil
    os.remove(path); os.remove(prefix); loader.invalidate(path)
    assert.truthy(ok, err)
  end)
end)
