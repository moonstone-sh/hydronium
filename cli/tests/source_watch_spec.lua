--[[
  hydronium-cli source_watch: when `hydronium dev --watch-sources` re-runs
  Ballad. Uses a real temp project directory (real files under a declared
  root, real `find`), since "a file appeared" is the behavior under test.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local source_watch = require("source_watch")

local function write(path, content)
  local f = io.open(path, "w")
  f:write(content)
  f:close()
end

local function project()
  local dir = os.tmpname()
  os.remove(dir)
  os.execute("mkdir -p '" .. dir .. "/src/views' '" .. dir .. "/elsewhere'")
  write(dir .. "/src/views/App.luax", "return 1")
  return dir
end

describe("source_watch", function()
  it("re-runs only when a file under a declared root appears or disappears", function()
    local dir = project()
    local runs = 0
    local config = dir .. "/hydronium.sources.lua"
    -- Roots are project-relative; popen runs `find` from the project dir.
    write(config, 'return { roots = { { path = "src/views", namespace = "views" } } }')
    local watcher = source_watch.new({
      run = function() runs = runs + 1; return true end,
      config_path = config,
      interval_ms = 0,
      popen = function(cmd, mode) return io.popen("cd '" .. dir .. "' && " .. cmd, mode) end,
    })
    watcher:prime()
    assert.is_nil(watcher:poll(1))

    write(dir .. "/src/views/App.luax", "return 2") -- content edit: HMR's job
    assert.is_nil(watcher:poll(2))
    write(dir .. "/elsewhere/Stray.luax", "return 3") -- outside every root
    assert.is_nil(watcher:poll(3))

    write(dir .. "/src/views/Card.luax", "return 4")
    local result = watcher:poll(4)
    assert.truthy(result and result.ok)
    assert.equal(runs, 1)

    os.remove(dir .. "/src/views/Card.luax")
    assert.truthy(watcher:poll(5))
    assert.equal(runs, 2)

    write(config, 'return { roots = { { path = "src/views", namespace = "ui" } } }')
    assert.truthy(watcher:poll(6))
    assert.equal(runs, 3)
    os.execute("rm -rf '" .. dir .. "'")
  end)

  it("respects its polling interval", function()
    local dir = project()
    write(dir .. "/hydronium.sources.lua", 'return { roots = { { path = "src/views" } } }')
    local runs = 0
    local watcher = source_watch.new({
      run = function() runs = runs + 1; return true end,
      config_path = dir .. "/hydronium.sources.lua",
      interval_ms = 1000,
      popen = function(cmd, mode) return io.popen("cd '" .. dir .. "' && " .. cmd, mode) end,
    })
    watcher:prime()
    assert.is_nil(watcher:poll(0))
    write(dir .. "/src/views/New.luax", "return 1")
    assert.is_nil(watcher:poll(500))
    assert.truthy(watcher:poll(1000))
    os.execute("rm -rf '" .. dir .. "'")
  end)
end)
