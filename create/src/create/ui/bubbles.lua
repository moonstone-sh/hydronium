--[[
  create.ui.bubbles -- the header "diorama": bubbles rising through a
  3-row band whose bottom row is the header text itself.

  LIFE OF A BUBBLE: it rises six cells -- three as a whole bubble "o", then
  dissipates one cell each as "*", "°" and "`" -- then rests (invisible)
  before rising again. Its spawn row is seeded: some start below the band
  and drift into view, others start inside it, so at any moment the band
  shows bubbles at every stage of life. The band simply clips each path.

  Far bubbles are instead a single braille dot climbing inside each cell
  ("⠄" bottom, "⠂" middle, "⠁" top) before moving up: finer, lighter
  motion that reads as a distant particle.

  DEPTH: each bubble is far, mid or near. Nearer bubbles are brighter and
  faster (parallax); a near bubble passes IN FRONT of the header text, mid
  and far ones pass BEHIND it (only visible in its gaps). Whole bubbles are
  gray at a depth-scaled intensity; dissipating ones take the pH colour of
  their column -- dim when far, vivid and bold when near.

  CHEAP AND DETERMINISTIC: nothing is stored between frames. Every bubble's
  cell is a closed-form function of (lane seed, monotonic time), so a frame
  costs O(lanes) and any frame can be snapshot-tested. Lanes are spaced
  every `SPACING` columns and seeded by index alone, so resizing only adds
  or removes lanes at the edge -- the others keep their exact motion.
]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local logo = require("create.ui.logo")

local M = {}

M.ROWS = 3
M.SPACING = 6

local PATH = { "o", "o", "o", "*", "\194\176", "`" } -- o o o * ° `
-- Far bubbles are a single braille dot climbing INSIDE each cell -- bottom,
-- middle, top -- before moving up a cell: three substeps per cell.
local FAR_DOTS = { "\226\160\132", "\226\160\130", "\226\160\129" } -- ⠄ ⠂ ⠁
local FAR, MID, NEAR = 1, 2, 3
-- Milliseconds per cell of rise; each bubble adds a seeded jitter.
local SPEED_MS = { [FAR] = 300, [MID] = 210, [NEAR] = 150 }

-- MINSTD (Park-Miller): exact in doubles (products stay below 2^47).
local function minstd(state) return (state * 48271) % 2147483647 end

local lane_cache = {}

--- The seeded, time-independent parameters of lane `i`.
local function lane(i)
  local cached = lane_cache[i]
  if cached then return cached end
  local s = minstd(i * 7919 + 17)
  local function next_int(n) s = minstd(s); return s % n end
  local depth = next_int(3) + 1
  local rest = 1 + next_int(4)
  cached = {
    offset = next_int(M.SPACING - 1),       -- column within its lane slot
    depth = depth,
    speed = SPEED_MS[depth] + next_int(60), -- constant for its whole life
    spawn = next_int(4) - 2,                -- rows from the band bottom: -2..1
    cycle = #PATH + rest,                   -- steps: rise, then rest
    phase = 0,
  }
  cached.phase = next_int(cached.cycle)
  lane_cache[i] = cached
  return cached
end

--- Every visible bubble at monotonic time `time_ms` in a band `columns`
--- wide. `row` counts from the top of the band (1..ROWS); the last row is
--- the header text row.
--- @return { col: integer, row: integer, ch: string, depth: integer, dissipating: boolean }[]
function M.field(columns, time_ms)
  local out = {}
  for i = 1, math.floor(columns / M.SPACING) do
    local l = lane(i)
    -- Far dots advance in thirds of a cell at the same vertical speed.
    local sub = l.depth == FAR and #FAR_DOTS or 1
    local t = (math.floor(time_ms * sub / l.speed) + l.phase * sub) % (l.cycle * sub)
    local step, within = math.floor(t / sub), t % sub
    if step < #PATH then
      local height = l.spawn + step -- 0 = header row
      if height >= 0 and height < M.ROWS then
        out[#out + 1] = {
          col = (i - 1) * M.SPACING + 1 + l.offset,
          row = M.ROWS - height,
          ch = l.depth == FAR and FAR_DOTS[within + 1] or PATH[step + 1],
          depth = l.depth,
          dissipating = step >= 3,
        }
      end
    end
  end
  return out
end

--- Is the bubble drawn in front of the header text?
function M.in_front(bubble) return bubble.depth == NEAR end

local WHOLE = {
  [FAR] = { color = "brightBlack", dimColor = true },
  [MID] = { color = "brightBlack" },
  [NEAR] = { color = "white" },
}

--- Text props for one bubble cell (column-dependent for the pH colour).
function M.style(bubble, columns)
  if not bubble.dissipating then return WHOLE[bubble.depth] end
  local color = logo.gradient_color(bubble.col, columns, 0)
  if bubble.depth == FAR then return { color = color, dimColor = true } end
  if bubble.depth == NEAR then return { color = color, bold = true } end
  return { color = color }
end

--- The two bubble-only rows above the header row, as elements. The header
--- row itself is composited by render_diorama below, which layers it.
--- @param props { time?: number, columns?: integer, bubbles?: table }
function M.render(props)
  props = props or {}
  local columns = math.max(1, props.columns or 80)
  local field = props.bubbles or M.field(columns, props.time or 0)
  local rows = {}
  for r = 1, M.ROWS - 1 do rows[r] = {} end
  for _, b in ipairs(field) do
    if b.row < M.ROWS and b.col <= columns then rows[b.row][b.col] = b end
  end
  local elements = {}
  for r = 1, M.ROWS - 1 do
    local cells, run = {}, {}
    local function flush()
      if #run > 0 then cells[#cells + 1] = hydronium.h(ink.Text, { key = #cells + 1 }, table.concat(run)); run = {} end
    end
    for c = 1, columns do
      local b = rows[r][c]
      if b then
        flush()
        local props_ = { key = #cells + 1 }
        for k, v in pairs(M.style(b, columns)) do props_[k] = v end
        cells[#cells + 1] = hydronium.h(ink.Text, props_, b.ch)
      else
        run[#run + 1] = " "
      end
    end
    flush()
    elements[r] = hydronium.h(ink.Box, { key = "bubbles" .. r, flexDirection = "row" }, cells)
  end
  return hydronium.h(ink.Box, { flexDirection = "column" }, elements)
end

local function absolute_cell(b, columns, key)
  local props_ = { key = key }
  for k, v in pairs(M.style(b, columns)) do props_[k] = v end
  return hydronium.h(ink.Box, { key = key, position = "absolute", top = 0, left = b.col - 1 },
    hydronium.h(ink.Text, props_, b.ch))
end

--- The whole 3-row diorama: two bubble rows, then the header row with
--- bubbles layered by depth -- mid/far painted first (the header text then
--- covers them, so they show only through its gaps), near painted last (in
--- front of the text).
--- @param props { time?: number, columns: integer }
--- @param header any the header row element (logo.render)
function M.render_diorama(props, header)
  local columns = math.max(1, props.columns or 80)
  local field = M.field(columns, props.time or 0)
  local behind, front = {}, {}
  for _, b in ipairs(field) do
    if b.row == M.ROWS and b.col <= columns then
      local list = M.in_front(b) and front or behind
      list[#list + 1] = absolute_cell(b, columns, (M.in_front(b) and "f" or "b") .. b.col)
    end
  end
  local layers = {}
  for _, e in ipairs(behind) do layers[#layers + 1] = e end
  layers[#layers + 1] = hydronium.h(ink.Box, { key = "header", flexGrow = 1 }, header)
  for _, e in ipairs(front) do layers[#layers + 1] = e end
  return hydronium.h(ink.Box, { flexDirection = "column" },
    M.render({ columns = columns, bubbles = field }),
    hydronium.h(ink.Box, { key = "header-row", position = "relative", width = columns, height = 1 }, layers))
end

return M
