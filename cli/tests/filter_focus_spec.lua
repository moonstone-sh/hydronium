--[[
  The filter bar as a real focusable component: `/` focuses it, keys go to it
  instead of the app shortcuts, and Esc hands focus back. Driven through the
  real app component and a real session.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local session = require("hydronium_ink.session")
local ui = require("ui.app")

local function boot()
  local quit_calls = 0
  local state = ui.new_state({ fullscreen = true })
  local App = ui.create_app(state, { onQuit = function() quit_calls = quit_calls + 1 end })
  local s = session.create(H.h(App), { writeFn = function() end, columns = 80, rows = 20 })
  return s, state, function() return quit_calls end
end

describe("hydronium_cli filter bar -- focus", function()
  it("takes keys only after `/` focuses it", function()
    local s, state = boot()
    s:write("m")
    assert.equal(state.search().text, "", "keys must not reach an unfocused filter")
    s:write("/")
    s:write("m")
    assert.equal(state.search().text, "m")
    s:close()
  end)

  it("does not let `q` quit while the filter has focus", function()
    local s, state, quits = boot()
    s:write("/")
    s:write("q")
    assert.equal(quits(), 0, "typing q into a filter must not quit the process")
    assert.equal(state.search().text, "q", "and it must land in the filter instead")
    s:close()
  end)

  it("does not let `f` leave the view while the filter has focus", function()
    local s, state = boot()
    s:write("/")
    s:write("f")
    assert.equal(state.fullscreen(), true, "f must not toggle the view while typing")
    assert.equal(state.search().text, "f")
    s:close()
  end)

  it("hands focus back on escape, restoring the shortcuts", function()
    local s, state, quits = boot()
    s:write("/")
    s:write("x")
    s:write("\27")
    -- The lone-ESC disambiguation window has to lapse before it is a real
    -- Escape rather than the start of a longer sequence.
    s:step(1000)
    s:write("q")
    assert.equal(quits(), 1, "q must quit again once the filter is blurred")
    assert.equal(state.search().text, "x", "blurring must not discard the filter")
    s:close()
  end)

  it("types a whole filter without any key leaking to a shortcut", function()
    local s, state, quits = boot()
    s:write("/")
    -- Contains q and f, both of which are app shortcuts.
    for _, ch in ipairs({ "m", "e", "t", "h", "o", "d", ":", "q", "f" }) do
      s:write(ch)
    end
    assert.equal(state.search().text, "method:qf")
    assert.equal(quits(), 0)
    assert.equal(state.fullscreen(), true)
    s:close()
  end)
end)
