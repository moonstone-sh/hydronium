--[[
  hydronium_create.ui.bubbles -- a scattered field of sparkling bubbles
  across the header's "diorama" row while the form is open. Each bubble
  cycles glyphs "o" -> "*" -> "°" -> "`" as it rises, dim gray for most of
  its life, then flashes into the bright, vibrant pH-gradient sequence for
  one "explode" frame before fading back to dim -- then goes quiet for the
  rest of its (precomputed, seeded) lifetime before rising again.

  Purely a function of a frame counter, no internal timer -- wizard_app.lua
  owns the real `hooks.useAnimation` ticker and passes its `frame()` in
  every render, the same pattern `logo.lua`'s `sweep` progress uses.

  "Precomputed, seeded, several, different lifetimes": BUBBLES below is a
  fixed table, not math.random -- each entry's `period` (lifetime length),
  `offset` (phase within that lifetime) and `explode` (the one frame, within
  its own cycle, where it flashes bright) were hand-picked to be
  co-prime-ish and staggered so no two bubbles explode in visible lockstep,
  and to keep this deterministic and snapshot-testable at any fixed frame
  instead of producing a different frame every time a test happens to run.
]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local logo = require("create.ui.logo")

local M = {}

local GLYPHS = { "o", "*", "\194\176", "`" } -- o, *, °, `

-- `lane` is a 0..1 fraction of the available width; `period`/`offset` pick
-- this bubble's own rise-and-fade cycle; `explode` is the one frame (mod
-- period) where it flashes the pH-gradient sequence instead of dim gray;
-- `visible` is how much of its own period it's actually on screen for
-- (a fraction < 1 leaves a quiet gap so the field doesn't feel saturated).
local BUBBLES = {
  { lane = 0.02, period = 17, offset = 2,  explode = 4,  visible = 0.6 },
  { lane = 0.09, period = 13, offset = 9,  explode = 11, visible = 0.7 },
  { lane = 0.16, period = 23, offset = 5,  explode = 2,  visible = 0.5 },
  { lane = 0.24, period = 11, offset = 0,  explode = 7,  visible = 0.8 },
  { lane = 0.33, period = 19, offset = 14, explode = 1,  visible = 0.6 },
  { lane = 0.41, period = 29, offset = 6,  explode = 18, visible = 0.5 },
  { lane = 0.49, period = 17, offset = 10, explode = 15, visible = 0.7 },
  { lane = 0.57, period = 13, offset = 3,  explode = 8,  visible = 0.6 },
  { lane = 0.65, period = 23, offset = 17, explode = 20, visible = 0.5 },
  { lane = 0.73, period = 19, offset = 8,  explode = 3,  visible = 0.7 },
  { lane = 0.81, period = 11, offset = 5,  explode = 9,  visible = 0.6 },
  { lane = 0.88, period = 29, offset = 21, explode = 25, visible = 0.5 },
  { lane = 0.94, period = 13, offset = 1,  explode = 6,  visible = 0.7 },
  { lane = 0.98, period = 17, offset = 12, explode = 16, visible = 0.6 },
}

--- @param props { frame: integer, columns?: integer }
--- @return any element
function M.render(props)
  props = props or {}
  local frame = props.frame or 0
  local columns = math.max(1, props.columns or 80)

  local glyph_at = {}
  for _, bubble in ipairs(BUBBLES) do
    local cycle = (frame + bubble.offset) % bubble.period
    if cycle < math.floor(bubble.period * bubble.visible) then
      local col = math.max(1, math.min(columns, math.floor(bubble.lane * columns) + 1))
      local exploding = cycle == bubble.explode or cycle == (bubble.explode + 1) % bubble.period
      glyph_at[col] = {
        ch = GLYPHS[(cycle % #GLYPHS) + 1],
        exploding = exploding,
      }
    end
  end

  local cells = {}
  for i = 1, columns do
    local b = glyph_at[i]
    if b then
      cells[i] = hydronium.h(ink.Text, {
        key = i,
        color = b.exploding and logo.gradient_color(i, columns, 0) or "brightBlack",
        bold = b.exploding,
        dimColor = not b.exploding,
      }, b.ch)
    else
      cells[i] = hydronium.h(ink.Text, { key = i }, " ")
    end
  end

  return hydronium.h(ink.Box, { flexDirection = "row" }, cells)
end

return M
