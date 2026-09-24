--[[
  hydronium_cli.ui.search_bar -- chips rendered through the REAL ink host,
  asserted on the painted bytes rather than on the element tree.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local hydronium = require("hydronium")
local session = require("hydronium_ink.session")
local query = require("query")
local field = require("ui.search_field")
local bar = require("ui.search_bar")

--- Paints the bar and returns the raw bytes the host wrote.
local function paint(text, cursor, opts)
  local state = field.new_state(text)
  if cursor then state.cursor = cursor end
  if opts and opts.anchor then state.anchor = opts.anchor end
  local tokens = query.tokenize(state.text)
  local out = {}
  local s = session.create(
    bar.render(state, tokens, { focused = opts and opts.focused }),
    { writeFn = function(b) out[#out + 1] = b end, columns = 100, rows = 10, color = "ansi16" })
  s:step()
  local bytes = table.concat(out)
  s:close()
  return bytes
end

--- Strips escapes, leaving only what a human would read on screen.
local function visible(bytes)
  return (bytes:gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("\27%][^\27]*\27\\", ""))
end

describe("hydronium_cli.ui.search_bar -- chips", function()
  it("renders a known tag as a padded two-part chip", function()
    local bytes = paint("method:GET", nil, { focused = false })
    local text = visible(bytes)
    -- Padding is real spaces so the background colour has cells to fill.
    assert.truthy(text:find(" method: ", 1, true), "expected a padded field label, got: " .. text)
    assert.truthy(text:find(" GET ", 1, true), "expected a padded value")
    -- And it is actually coloured, not just spaced.
    assert.truthy(bytes:find("\27[", 1, true), "expected SGR colour output")
  end)

  it("marks an unknown field differently from a known one", function()
    local known = paint("method:GET", nil, { focused = false })
    local unknown = paint("nope:GET", nil, { focused = false })
    assert.not_equal(known, unknown)
    assert.truthy(visible(unknown):find(" nope: ", 1, true))
  end)

  it("shows a negated tag with its leading dash", function()
    local text = visible(paint("-status:5xx", nil, { focused = false }))
    assert.truthy(text:find(" -status: ", 1, true), "got: " .. text)
  end)

  it("renders the token under the caret as raw text, not a chip", function()
    -- Caret inside `method:GET` -> raw, so it stays editable.
    local focused = visible(paint("method:GET", 3, { focused = true }))
    -- Raw text has no padded chip label.
    assert.falsy(focused:find(" method: ", 1, true),
      "the token being edited must not be chipped: " .. focused)
    assert.truthy(focused:find("method:GET", 1, true))
  end)

  it("chips a token once the caret leaves it", function()
    -- Caret parked at the very end, past a completed first token.
    local text = visible(paint("method:GET other", 16, { focused = true }))
    assert.truthy(text:find(" method: ", 1, true), "got: " .. text)
  end)

  it("renders placeholder help when empty", function()
    local text = visible(paint("", nil, { focused = false }))
    assert.truthy(text:find("method:GET", 1, true), "expected example syntax as a hint")
  end)

  it("paints a selection highlight", function()
    local plain = paint("method:GET", 10, { focused = true })
    local selected = paint("method:GET", 10, { focused = true, anchor = 7 })
    assert.not_equal(plain, selected, "a selection must change what is painted")
  end)

  it("never loses characters, whatever the caret position", function()
    -- The caret splits a token into up-to-three Text runs; an off-by-one in
    -- that arithmetic silently eats a character, which is exactly the class
    -- of bug this catches.
    for cursor = 0, 10 do
      local text = visible(paint("method:GET", cursor, { focused = true }))
      local stripped = text:gsub("%s", "")
      assert.truthy(stripped:find("method:GET", 1, true),
        string.format("caret at %d lost characters: %q", cursor, text))
    end
  end)
end)
describe("hydronium_cli.ui.search_bar -- atomic wrapping", function()
  --- The painted grid as plain text rows. getLastFrame() returns the cell
  --- grid, which is what makes "did this chip survive the row break" a
  --- question with a definite answer rather than an eyeball judgement.
  local function rows(text, columns)
    local state = field.new_state(text)
    local tokens = query.tokenize(text)
    local s = session.create(bar.render(state, tokens, { focused = false }),
      { writeFn = function() end, columns = columns, rows = 12, color = "ansi16" })
    s:step()
    local frame = s:frame()
    local out = {}
    for y = 1, frame.h do
      local chars = {}
      for x = 1, frame.w do chars[x] = frame.rows[y][x].ch end
      out[y] = table.concat(chars)
    end
    s:close()
    return out
  end

  local WIDE = "method:GET status:200 path:/api mime:json origin:local ip:127"

  it("wraps a chip whole rather than splitting it across rows", function()
    local painted = rows(WIDE, 40)
    assert.truthy(#painted > 1, "expected the bar to wrap at width 40")

    -- Each chip label must appear complete on some single row. A split would
    -- leave a fragment ending one row and the rest opening the next, which is
    -- exactly what flex-item atomicity prevents: a Box is never divided.
    for _, label in ipairs({ " method: ", " status: ", " path: ", " mime: ", " origin: ", " ip: " }) do
      local found = false
      for _, line in ipairs(painted) do
        if line:find(label, 1, true) then found = true break end
      end
      assert.truthy(found,
        "chip label split across rows: " .. label .. "\n" .. table.concat(painted, "\n"))
    end
  end)

  it("keeps a chip's field and value together on the same row", function()
    local painted = rows(WIDE, 40)
    for _, line in ipairs(painted) do
      if line:find(" mime: ", 1, true) then
        assert.truthy(line:find(" json ", 1, true),
          "a chip's value must wrap with its field:\n" .. table.concat(painted, "\n"))
      end
    end
  end)
end)
