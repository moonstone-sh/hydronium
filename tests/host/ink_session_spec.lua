local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local session = require("hydronium_ink.session")

local function text(frame, row)
  local out = {}
  for x = 1, frame.w do out[x] = frame.rows[row][x].ch end
  return table.concat(out)
end

describe("hydronium_ink.session", function()
  it("drives input, paste and resize without a TTY or blocking loop", function()
    local function App()
      local value, setValue = hydronium.signal("ready")
      hooks.useInput(function(input, key)
        if key.rightArrow then setValue("right") elseif input ~= "" then setValue(input) end
      end)
      hooks.usePaste(function(input) setValue("paste:" .. input) end)
      return function()
        local size = hooks.useWindowSize()
        return hydronium.h(ink.Text, nil, value() .. " " .. size.columns .. "x" .. size.rows)
      end
    end

    local app = session.create(hydronium.h(App), { columns = 30, rows = 4 })
    assert.truthy(text(app:frame(), 1):find("ready 30x4", 1, true))
    app:dispatch({ type = "key", input = "", key = { rightArrow = true } })
    assert.truthy(text(app:frame(), 1):find("right 30x4", 1, true))
    app:paste("hello")
    assert.truthy(text(app:frame(), 1):find("paste:hello", 1, true))
    app:resize(18, 3)
    assert.equal(app:frame().w, 18)
    assert.equal(app:frame().h, 3)
    assert.truthy(text(app:frame(), 1):find("18x3", 1, true))
    app:close()
    assert.truthy(app:status().closed)
  end)

  it("advances animation tickers only when explicitly stepped", function()
    local animation
    local function App()
      animation = hooks.useAnimation({ interval = 1 })
      return hydronium.h(ink.Text, nil, "clock")
    end
    local app = session.create(hydronium.h(App))
    assert.equal(animation.frame(), 0)
    app:step(100)
    app:step(140)
    assert.equal(animation.frame(), 1)
    assert.equal(animation.delta(), 40)
    app:close()
  end)
end)
