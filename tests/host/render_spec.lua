--[[
  hydronium_ink.render -- deterministic coverage for the pieces of
  render()'s Phase 4 surface (useCursor) that don't require a real
  interactive TTY loop to exercise for real.

  SCOPE NOTE: useFocus/useFocusManager (Tab/Shift+Tab dispatch),
  useAnimation (real wall-clock ticking), and usePaste (bracketed-paste
  byte parsing through the real event loop) were all verified via real
  tmux sessions injecting actual keystrokes/paste bytes into a live pty
  running render() -- the same "verify for real, not a mock" bar this
  repo's own docs (see docs/HYDRONIUM_INK_TERMINAL_HOST.md) hold
  render.lua's whole interactive loop to, and the same reason Phase 1's
  own render() event loop has no permanent automated spec either: it's a
  real blocking loop over real stdin, not something a deterministic unit
  test can drive without a real pty. Only useCursor is covered here,
  because it needs no stdin interaction at all -- `render()` accepts an
  injectable `opts.writeFn` (see render.lua's own doc comment) precisely
  so a test can capture the exact bytes it writes without a real
  terminal, and exit() can be called directly from a component's setup
  call rather than needing a keypress to trigger it.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local render = require("hydronium_ink.render")

describe("hydronium_ink.render -- useCursor", function()
  it("writes a real move-to+show-cursor escape sequence, converting 0-based position to 1-based terminal coordinates", function()
    local captured = {}
    local function fakeWrite(s)
      table.insert(captured, s)
    end

    local function App()
      local cursor = hooks.useCursor()
      local exit = hooks.useApp().exit
      cursor.setCursorPosition({ x = 5, y = 2 })
      exit()
      return function()
        return hydronium.h(ink.Text, {}, "hi")
      end
    end

    render.render(hydronium.h(App), { writeFn = fakeWrite })

    local all = table.concat(captured)
    assert.truthy(
      all:find("\27[3;6H\27[?25h", 1, true),
      "expected a move-to (row=3, col=6) + show-cursor sequence for {x=5, y=2}"
    )
  end)

  it("writes a real hide-cursor escape sequence when called with nil", function()
    local captured = {}
    local function fakeWrite(s)
      table.insert(captured, s)
    end

    local function App()
      local cursor = hooks.useCursor()
      local exit = hooks.useApp().exit
      cursor.setCursorPosition(nil)
      exit()
      return function()
        return hydronium.h(ink.Text, {}, "hi")
      end
    end

    render.render(hydronium.h(App), { writeFn = fakeWrite })

    local all = table.concat(captured)
    assert.truthy(all:find("\27[?25l", 1, true), "expected a hide-cursor sequence")
  end)
end)
