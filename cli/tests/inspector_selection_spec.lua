--[[
  hydronium-cli fullscreen inspector -- selection stays in range while the
  filtered list resizes underneath it.

  BUG THIS REPRODUCES: typing a filter that shrinks the visible list left
  the stored selection wherever it was in the UNFILTERED list. The key
  handler (ui/app.lua's `move`, `g`, `G`) clamped a keypress against
  `state.history:count()` -- the raw, unfiltered count -- while the view
  (ui/inspector_view.lua) always painted against the FILTERED count. The
  two agreeing by coincidence with no filter active hid this; the moment a
  filter shrank the list below the stored selection, up/down kept nudging
  a number that was already far outside what the screen showed, the
  painted cursor (re-clamped locally, just for display) never budged, and
  the list looked stuck -- only `g`/`home` (which happened to reset the
  selection to 1, inside the new bounds) unstuck it.

  Driven through the real app component and a real session, exactly like
  cli/tests/filter_focus_spec.lua and cli/tests/inspector_filter_spec.lua,
  because the bug lives in the interaction between the key handler and the
  view, not in either piece of pure arithmetic alone (see
  cli/tests/inspector_spec.lua's own new case for the pure half of this,
  `move_selection`'s clamp-then-move fix).
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local session = require("hydronium_ink.session")
local ui = require("ui.app")
local search_field = require("ui.search_field")

local function req(method, path, status)
  return {
    v = 1, source = "meteorite", kind = "request", ts = 1,
    method = method, path = path, status = status, duration_ms = 5,
  }
end

--- Boots the real fullscreen app with `count` requests recorded (methods
--- alternate GET/POST so a `method:` filter can shrink the list), returns
--- the session, state, and a helper that paints one frame and returns it
--- as plain text (needed to see which row is actually marked `>`).
local function boot(count)
  local state = ui.new_state({ fullscreen = true })
  for i = 1, count do
    state:record_request(req(i % 2 == 0 and "POST" or "GET", "/item/" .. i, 200))
  end
  local App = ui.create_app(state, {})
  local s = session.create(H.h(App), { writeFn = function() end, columns = 90, rows = 20 })

  local function text()
    s:step()
    local frame = s:frame()
    local out = {}
    for y = 1, frame.h do
      local chars = {}
      for x = 1, frame.w do chars[x] = frame.rows[y][x].ch end
      out[y] = table.concat(chars)
    end
    return table.concat(out, "\n")
  end

  return s, state, text
end

--- Filters without going through the focusable bar (same shortcut
--- cli/tests/inspector_filter_spec.lua uses) -- what matters here is the
--- key handler's reaction to the list resizing, not focus routing, which
--- cli/tests/filter_focus_spec.lua already covers on its own.
local function set_filter(state, query)
  state.set_search(search_field.new_state(query))
  state.set_search_revision(state.search_revision() + 1)
end

describe("hydronium-cli fullscreen inspector -- selection vs. a resizing filtered list", function()
  it("moves immediately on the very first up/down press after a filter shrinks the list, no `g` needed", function()
    local s, state, text = boot(5)
    text() -- first paint: follow-the-tail pins selection to the newest row (5).
    assert.equal(state.selection(), 5)

    -- Narrow to the 2 POST rows (items 2 and 4). The stored selection (5)
    -- is now well outside the filtered list.
    set_filter(state, "method:POST")
    local frame = text()
    assert.truthy(frame:find("filtered from 5", 1, true), "header must say the list is filtered:\n" .. frame)
    -- The view paints a locally-clamped cursor even before any key is
    -- pressed, so the display itself was never wrong -- only movement was.
    assert.truthy(frame:find("> POST   /item/4", 1, true), "display already clamps to the last visible row:\n" .. frame)

    -- One single "up" press. Before the fix this was a no-op (the stored
    -- selection wandered from 5 to 4, both of which clamp for DISPLAY to
    -- the same row), and it took a second or third press to actually move.
    s:write("k")
    frame = text()
    assert.truthy(frame:find("> POST   /item/2", 1, true),
      "a single `k` must move onto the other visible row immediately:\n" .. frame)
    assert.equal(state.selection(), 1, "the stored selection must itself be in range, not just the paint")

    s:close()
  end)

  it("does not get stuck pressing down at the shrunk list's boundary either", function()
    local s, state, text = boot(5)
    text()

    set_filter(state, "method:POST")
    text()

    -- Already effectively at the bottom of the 2-row filtered list;
    -- pressing down repeatedly must hold there, not silently do nothing
    -- forever nor wander off past the end of the filtered list.
    for _ = 1, 3 do
      s:write("j")
    end
    local frame = text()
    assert.truthy(frame:find("> POST   /item/4", 1, true), "down at the bottom must hold the last row:\n" .. frame)
    assert.equal(state.selection(), 2)

    s:close()
  end)

  it("handles the empty-filter-result case: no crash, and typing more/less keeps it sane", function()
    local s, state, text = boot(3)
    text()

    set_filter(state, "method:PATCH") -- matches nothing
    local frame = text()
    assert.truthy(frame:find("none match filter", 1, true), "must say nothing matched, not \"none captured yet\":\n" .. frame)
    -- The RAW stored selection is only re-clamped when a key is actually
    -- handled (the render's own clamp is a local, display-only value --
    -- see inspector_view.lua's own note on why it cannot write the signal
    -- back during render). So the very first keypress against a
    -- zero-item filtered list is what must not error and must land on 0,
    -- not the render alone.
    s:write("j")
    text()
    assert.equal(state.selection(), 0, "down against zero visible rows must clamp to 0, not error or wander")
    s:write("k")
    s:write("g")
    text()
    assert.equal(state.selection(), 0)

    -- Growing back: clearing the filter restores the full list, and the
    -- selection is simply re-clamped into the now-larger range rather than
    -- reset or left dangling.
    set_filter(state, "")
    frame = text()
    assert.truthy(frame:find("Requests 1-3 of 3", 1, true), "the full list must return once the filter clears:\n" .. frame)
    s:write("k")
    text()
    assert.truthy(state.selection() >= 1 and state.selection() <= 3, "selection must be back in a valid range")

    s:close()
  end)

  it("`g`/home already worked as an escape hatch; up/down must not need it any more", function()
    local s, state, text = boot(6)
    text()
    assert.equal(state.selection(), 6)

    set_filter(state, "path:/item/1") -- matches only /item/1 (1 row)
    text()

    -- `g` still works (it always did -- this is the regression guard).
    s:write("g")
    text()
    assert.equal(state.selection(), 1)

    s:close()
  end)
end)
