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

describe("hydronium_ink.render -- alternate screen", function()
  local ENTER = "\27[?1049h"
  local LEAVE = "\27[?1049l"

  it("switches in before the first paint and back out when render returns, given opts.altScreen", function()
    local captured = {}
    local function fakeWrite(s)
      table.insert(captured, s)
    end

    local firstPaintAt = nil
    local function App()
      local exit = hooks.useApp().exit
      exit()
      return function()
        -- Records where in the write stream the first frame landed, so
        -- "switched in BEFORE the first paint" is a real assertion rather
        -- than just "both sequences appear somewhere".
        firstPaintAt = #captured + 1
        return hydronium.h(ink.Text, {}, "fullscreen")
      end
    end

    render.render(hydronium.h(App), { writeFn = fakeWrite, altScreen = true })

    local all = table.concat(captured)
    local enterAt = all:find(ENTER, 1, true)
    local leaveAt = all:find(LEAVE, 1, true)
    assert.truthy(enterAt, "expected a DECSET 1049 enter sequence")
    assert.truthy(leaveAt, "expected a DECSET 1049 leave sequence on the way out")
    assert.truthy(leaveAt > enterAt, "the leave sequence must come after the enter sequence")
    assert.truthy(firstPaintAt, "the app must have rendered at least once")
    assert.truthy(
      table.concat(captured, "", 1, firstPaintAt - 1):find(ENTER, 1, true),
      "the alternate screen must be entered before the first frame is painted"
    )
    assert.truthy(all:find("fullscreen", 1, true), "the frame itself must still be painted")
  end)

  it("useAltScreen().toggle() switches at runtime and reports state through its reactive getter", function()
    local captured = {}
    local function fakeWrite(s)
      table.insert(captured, s)
    end

    local seen = {}
    local toggle, isActive, stop
    local ticks = 0
    local function App()
      local alt = hooks.useAltScreen()
      toggle, isActive = alt.toggle, alt.isActive
      stop = hooks.useApp().exit
      return function()
        table.insert(seen, alt.isActive())
        return hydronium.h(ink.Text, {}, alt.isActive() and "alt" or "normal")
      end
    end

    render.render(hydronium.h(App), {
      writeFn = fakeWrite,
      -- Everything is driven from onTick, which runs outside any render --
      -- exactly where a real key handler runs. (Ending the loop from the
      -- render closure instead would never happen: that closure only
      -- re-runs when a signal it reads changes.)
      onTick = function()
        ticks = ticks + 1
        if ticks == 1 then
          toggle()
        elseif ticks == 2 then
          toggle()
        else
          stop()
        end
      end,
    })

    local all = table.concat(captured)
    assert.equal(seen[1], false, "the first render happens on the normal screen")
    assert.truthy(all:find(ENTER, 1, true), "toggle() must switch into the alternate screen")
    assert.falsy(isActive(), "toggling twice must end up back on the normal screen")
    -- Exactly one enter and one leave: the second toggle leaves, and
    -- render()'s teardown must not emit a redundant second leave.
    local _, enters = all:gsub("\27%[%?1049h", "")
    local _, leaves = all:gsub("\27%[%?1049l", "")
    assert.equal(enters, 1, "expected exactly one enter sequence")
    assert.equal(leaves, 1, "expected exactly one leave sequence")

    local sawAlt = false
    for _, value in ipairs(seen) do
      if value then
        sawAlt = true
      end
    end
    assert.truthy(sawAlt, "isActive() must report true to a render that happens while in the alternate screen")
  end)

  it("leaves the alternate screen even when a component error propagates out of the loop", function()
    local captured = {}
    local function fakeWrite(s)
      table.insert(captured, s)
    end

    local function App()
      local alt = hooks.useAltScreen()
      alt.enter()
      return function()
        return hydronium.h(ink.Text, {}, "boom")
      end
    end

    local ok = pcall(render.render, hydronium.h(App), {
      writeFn = fakeWrite,
      onTick = function()
        error("component blew up")
      end,
    })

    assert.falsy(ok, "the error must still propagate out of render()")
    local all = table.concat(captured)
    assert.truthy(all:find(ENTER, 1, true), "entering from a component's setup call must work")
    assert.truthy(all:find(LEAVE, 1, true), "the alternate screen must be left on the error path too")
  end)
end)

describe("hydronium_ink.render -- host extensions", function()
  it("runs onTick inside the live loop before flushing", function()
    local stop
    local ticks = 0
    local function App()
      stop = hooks.useApp().exit
      return function() return hydronium.h(ink.Text, {}, "live") end
    end

    render.render(hydronium.h(App), {
      writeFn = function() end,
      onTick = function()
        ticks = ticks + 1
        stop()
      end,
    })
    assert.equal(ticks, 1)
  end)
end)
