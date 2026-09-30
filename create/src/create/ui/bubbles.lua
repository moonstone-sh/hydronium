--[[
  create.ui.bubbles -- the header "diorama": bubbles rising through a
  4-row band under the wizard's brand line -- two open rows (the fizz's
  ceiling), the centered reaction, one open row below it:

      row 1   .   .   °       .
      row 2       *       o
      row 3        CH₃COOH + H₂O → CH₃COO⁻ + H₃O⁺   (title)
      row 4     o       o
      ~~~~~   bubbles are born out of window, below row 4

  FIZZ: given `start` (H₃O⁺ lighting up, create.ui.fizzing) the field is
  empty before it, then bursts -- first launches within ~0.3s from the
  bottom row, plus a second set of half-offset lanes -- and after `burst_ms`
  settles to an idle fizz: the extra lanes and two thirds of the regular
  ones finish the bubble in flight and launch no more. Without `start` the
  field is the original always-on ambient one.

  LIFE OF A BUBBLE: it rises six cells -- three as a whole bubble "o", then
  dissipates one cell each as "*", "°" and "`" -- then rests (invisible)
  before rising again. Every bubble is born below the window (a seeded 1-3
  cells down) and rises into it, so none pops into existence mid-air; the
  seeded depth decides whether it is still whole or already dissipating by
  the time it passes the title. The band simply clips each path.

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

M.ROWS = 4
M.TITLE_ROW = 3
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
    spawn = -1 - next_int(3),               -- born out of window: 1..3 below
    cycle = #PATH + rest,                   -- steps: rise, then rest
    phase = 0,
  }
  cached.phase = next_int(cached.cycle)
  -- About a third of the lanes keep fizzing once the burst settles to idle.
  cached.idle = next_int(3) == 0
  lane_cache[i] = cached
  return cached
end

--- Sub-step `t` within lane `l`'s current cycle, or nil when the lane shows
--- nothing at `time_ms`.
---
--- Without `opts.start` every lane runs forever from a seeded phase (the
--- original ambient field). With it, the fizz begins at `start`: each lane
--- first launches after a seeded delay, so bubbles rise in from below
--- rather than appearing mid-air. With `burst_ms` too, lanes not marked
--- `idle` stop launching new bubbles once the burst ends, but always finish
--- the one in flight.
local function lane_tick(l, sub, time_ms, opts, burst_only)
  local cycle_len = l.cycle * sub
  if not opts.start then
    return (math.floor(time_ms * sub / l.speed) + l.phase * sub) % cycle_len
  end
  -- First launches are spread over ~0.3s and start at the band's bottom
  -- row (skipping the hidden cells below it), so the fizz visibly begins
  -- the moment it is started.
  local first_launch = opts.start + (l.phase % 4) * l.speed * 0.25
  if time_ms < first_launch then return nil end
  local t = math.floor((time_ms - first_launch) * sub / l.speed) + (-l.spawn) * sub
  local cycle_index = math.floor(t / cycle_len)
  if opts.burst_ms and (burst_only or not l.idle) then
    local cycle_began = first_launch + (cycle_index * l.cycle + l.spawn) * l.speed
    if cycle_index > 0 and cycle_began >= opts.start + opts.burst_ms then return nil end
  end
  return t % cycle_len
end

--- Every visible bubble at monotonic time `time_ms` in a band `columns`
--- wide. `row` counts from the top of the band (1..ROWS); TITLE_ROW is
--- the header text row.
--- @param opts? { start?: number, burst_ms?: number } see lane_tick
--- @return { col: integer, row: integer, ch: string, depth: integer, dissipating: boolean }[]
function M.field(columns, time_ms, opts)
  opts = opts or {}
  local out = {}
  local lanes = math.floor(columns / M.SPACING)
  -- During a burst a second set of lanes, offset half a slot, doubles the
  -- density; they launch no new bubbles once the burst is over.
  local total = (opts.start and opts.burst_ms) and lanes * 2 or lanes
  for n = 1, total do
    local burst_lane = n > lanes
    local i = burst_lane and (n - lanes) or n
    local l = burst_lane and lane(10000 + i) or lane(i)
    -- Far dots advance in thirds of a cell at the same vertical speed.
    local sub = l.depth == FAR and #FAR_DOTS or 1
    local t = lane_tick(l, sub, time_ms, opts, burst_lane)
    local step, within = t and math.floor(t / sub) or #PATH, t and t % sub or 0
    local col = (i - 1) * M.SPACING + 1 + (burst_lane and (l.offset + math.floor(M.SPACING / 2)) % M.SPACING or l.offset)
    if step < #PATH and col <= columns then
      local height = l.spawn + step -- 0 = the band's bottom row
      if height >= 0 and height < M.ROWS then
        out[#out + 1] = {
          col = col,
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

--- One bubble-only row of the band (any row but TITLE_ROW) as an element.
local function render_row(field, r, columns)
  local by_col = {}
  for _, b in ipairs(field) do
    if b.row == r and b.col <= columns then by_col[b.col] = b end
  end
  local cells, run = {}, {}
  local function flush()
    if #run > 0 then cells[#cells + 1] = hydronium.h(ink.Text, { key = #cells + 1 }, table.concat(run)); run = {} end
  end
  for c = 1, columns do
    local b = by_col[c]
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
  return hydronium.h(ink.Box, { key = "bubbles" .. r, flexDirection = "row", height = 1 }, cells)
end

local function absolute_cell(b, columns, key)
  local props_ = { key = key }
  for k, v in pairs(M.style(b, columns)) do props_[k] = v end
  return hydronium.h(ink.Box, { key = key, position = "absolute", top = 0, left = b.col - 1 },
    hydronium.h(ink.Text, props_, b.ch))
end

--- The whole diorama: open rows around the title row, which is layered
--- by depth -- mid/far bubbles painted first (the title text then covers
--- them, so they show only through its gaps), near ones painted last (in
--- front of the text).
--- @param props { time?: number, columns: integer, start?: number, burst_ms?: number, still?: boolean }
---   `start`/`burst_ms`: see M.field; `still`: no bubbles at all (reduced motion).
--- @param header any the title row element
function M.render_diorama(props, header)
  local columns = math.max(1, props.columns or 80)
  local field = props.still and {} or M.field(columns, props.time or 0, { start = props.start, burst_ms = props.burst_ms })
  local behind, front = {}, {}
  for _, b in ipairs(field) do
    if b.row == M.TITLE_ROW and b.col <= columns then
      local list = M.in_front(b) and front or behind
      list[#list + 1] = absolute_cell(b, columns, (M.in_front(b) and "f" or "b") .. b.col)
    end
  end
  local layers = {}
  for _, e in ipairs(behind) do layers[#layers + 1] = e end
  layers[#layers + 1] = hydronium.h(ink.Box, { key = "header", flexGrow = 1 }, header)
  for _, e in ipairs(front) do layers[#layers + 1] = e end
  local rows = {}
  for r = 1, M.ROWS do
    rows[r] = r == M.TITLE_ROW
      and hydronium.h(ink.Box, { key = "title-row", position = "relative", width = columns, height = 1 }, layers)
      or render_row(field, r, columns)
  end
  return hydronium.h(ink.Box, { flexDirection = "column" }, rows)
end

return M
