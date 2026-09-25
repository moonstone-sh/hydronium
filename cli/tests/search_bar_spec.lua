--[[
  hydronium_cli.ui.search_bar -- chips rendered through the REAL ink host,
  asserted on the painted bytes rather than on the element tree.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local hydronium = require("hydronium")
local session = require("hydronium_ink.session")
local ink_color = require("hydronium_ink.color")
local oklab = require("hydronium_oklab_utils")
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

describe("hydronium_cli.ui.search_bar -- chip contrast (APCA, post-quantization)", function()
  -- Guards the actual point of the OKLCH rewrite: each chip role's {bg, fg}
  -- must stay legible not just as requested (truecolor) but as it will
  -- REALLY paint once hydronium_ink.color quantizes it down to 256 colors --
  -- the old palette-name chips ("blue"/"white"/"yellow"/"cyan") could never
  -- even be checked this way, since a palette name has no absolute RGB
  -- until the user's own terminal theme supplies one.
  --
  -- ansi16/"none" are NOT color-quantization cases any more (see
  -- `ui/search_bar.lua`'s own `STRUCTURAL_STYLE` doc comment for why: an
  -- ansi16 slot's RGB is theme-guessed, so contrast math against it is
  -- false precision, not a real guarantee) -- those are checked by the
  -- separate structural-style `describe` below instead.
  --
  -- `bar.build_colors(nil, capability)` -- no detected terminal background
  -- -- is used rather than the live, TTY-detecting `colors()` so this is
  -- deterministic under the test runner (never a real TTY).
  local ROLES = { "field", "unknown_field", "value", "selection", "caret" }
  local CAPABILITIES = { "truecolor", "ansi256" }

  -- APCA's own commonly-cited floor for small/bold text (matches
  -- `ui/search_bar.lua`'s own TEXT_LC) -- both truecolor and ansi256 must
  -- clear it for REAL, post-quantization, not just as requested: ansi256's
  -- own `derive_chip_colors` re-verifies and nudges specifically so this
  -- holds rather than the softer historical floor of 40.
  local MIN_LC = 60

  --- @return number lc, table eff_bg, table eff_fg
  local function painted_lc(bg, fg, capability)
    local eff_bg = ink_color.effective_srgb(ink_color.resolve(bg), capability)
    local eff_fg = ink_color.effective_srgb(ink_color.resolve(fg), capability)
    local lc = oklab.lc(oklab.srgb(eff_fg.r, eff_fg.g, eff_fg.b), oklab.srgb(eff_bg.r, eff_bg.g, eff_bg.b))
    return lc, eff_bg, eff_fg
  end

  for _, capability in ipairs(CAPABILITIES) do
    for _, role in ipairs(ROLES) do
      it("keeps '" .. role .. "' at or above Lc " .. MIN_LC .. " under " .. capability .. ", post-quantization", function()
        local pair = bar.build_colors(nil, capability)[role]
        local lc = painted_lc(pair.bg, pair.fg, capability)
        assert.truthy(math.abs(lc) >= MIN_LC,
          string.format("%s under %s: |Lc|=%.1f < floor %d", role, capability, math.abs(lc), MIN_LC))
      end)
    end
  end

  it("derives a real OKLCH color, not a palette name, for every role, under truecolor and ansi256", function()
    for _, capability in ipairs(CAPABILITIES) do
      local built = bar.build_colors(nil, capability)
      for _, role in ipairs(ROLES) do
        assert.truthy(built[role].bg.space, capability .. ": expected an oklab-utils color value for " .. role .. " bg")
        assert.truthy(built[role].fg.space, capability .. ": expected an oklab-utils color value for " .. role .. " fg")
      end
    end
  end)

  it("pushes a chip background away from a detected terminal background that would collide with it", function()
    -- The 'value' role's default is a pale near-white -- picking a nearly
    -- identical pale terminal background must not leave it blending in.
    local collidingTerminalBg = oklab.hex("#ece9df")
    local isolated = bar.build_colors(nil).value.bg
    local separated = bar.build_colors(collidingTerminalBg).value.bg
    local isolatedLc = math.abs(oklab.lc(isolated, collidingTerminalBg))
    local separatedLc = math.abs(oklab.lc(separated, collidingTerminalBg))
    assert.truthy(separatedLc > isolatedLc,
      string.format("expected separation to improve bg-vs-terminal contrast: %.1f -> %.1f", isolatedLc, separatedLc))
  end)
end)

describe("hydronium_cli.ui.search_bar -- structural style (ansi16 / none)", function()
  -- ansi16's own 16 RGB values are theme-defined, not real absolute colors
  -- (see search_bar.lua's own STRUCTURAL_STYLE doc comment) -- so, unlike
  -- truecolor/ansi256 above, there is no APCA number to assert on here.
  -- What's checkable instead: every role gets a REAL, non-empty structural
  -- override (never silently falling through to plain, undecorated text),
  -- and no role's style prop leaks an absolute color -- only `inverse`/
  -- `bold` (this package's stated design: NO_COLOR/ansi16 lean on the
  -- terminal's own theme, never a guessed hue).
  local ROLES = { "field", "unknown_field", "value", "selection", "caret" }
  local PROFILES = { "ansi16", "none" }
  local ALLOWED_KEYS = { inverse = true, bold = true }

  for _, profile in ipairs(PROFILES) do
    it("gives every role a non-empty inverse/bold-only style under " .. profile, function()
      local built = bar.build_colors(nil, profile)
      for _, role in ipairs(ROLES) do
        local style = built[role]
        assert.truthy(type(style) == "table", profile .. ": expected a structural style table for " .. role)
        assert.falsy(style.bg, profile .. ": " .. role .. " must not carry an absolute background color")
        assert.falsy(style.fg, profile .. ": " .. role .. " must not carry an absolute foreground color")
        for key in pairs(style) do
          assert.truthy(ALLOWED_KEYS[key], profile .. ": " .. role .. " has an unexpected style key '" .. key .. "'")
        end
        assert.truthy(style.inverse or style.bold,
          profile .. ": " .. role .. " must set inverse and/or bold, or it would look like plain text")
      end
    end)
  end

  it("keeps every chip role distinguishable from plain, undecorated raw text", function()
    -- Plain raw text (an untouched Text run) has neither flag set --
    -- asserted above already ensures no role matches that exact shape, but
    -- spelling it out here as its own assertion documents WHY that check
    -- exists: {} would be visually indistinguishable from ordinary text.
    for _, profile in ipairs(PROFILES) do
      local built = bar.build_colors(nil, profile)
      for _, role in ipairs(ROLES) do
        local style = built[role]
        assert.falsy(style.inverse == nil and style.bold == nil,
          profile .. ": " .. role .. " resolved to no style at all")
      end
    end
  end)

  it("field props end up bold via style_text_props for every profile, matching chip()'s own guarantee", function()
    -- chip() always forces `bold = true` on the field label regardless of
    -- profile (see its own doc comment) -- this just confirms the
    -- structural source data agrees for ansi16/none, so that forced
    -- assignment is reinforcing the design, not papering over a gap in it.
    for _, profile in ipairs(PROFILES) do
      assert.truthy(bar.build_colors(nil, profile).field.bold,
        profile .. ": expected the field role's own structural style to already be bold")
    end
  end)
end)
