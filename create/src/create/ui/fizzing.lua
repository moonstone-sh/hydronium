--[[
  create.ui.fizzing -- the header's one-shot reaction: an acid donating a
  proton to water, revealed one character at a time, spaces included, at a
  uniform tick:

      CH₃COOH + H₂O → CH₃COO⁻ + H₃O⁺

  TIMELINE (milliseconds from the start of the intro):
    - character i reveals at (i - 1) * CHAR_MS: it flashes white/bold for
      FLASH_MS, then settles into its role's indicator color;
    - H₃O⁺'s first character lighting up is `lit_at`: the bubbles start
      fizzing there (create.ui.bubbles), and H₃O⁺ takes the pH gradient,
      shimmering while the fizz bursts (BURST_MS), then holding still;
    - after the last character settles, the reactants fade to dim gray over
      FADE_MS -- only H₃O⁺ keeps its color.

  One reaction is picked per run. Its line hugs its own text, so whoever
  places it (the wizard centers it) centers the reaction itself. `width()`
  -- the widest reaction's -- is only for layout decisions (does the full
  line fit?), so the header's shape never depends on which one was picked.

  Universal-indicator-inspired acid/base roles, not measured molecular pH:
  pH describes an aqueous solution and depends on concentration/equilibrium.
]]
local H = require("hydronium")
local ink = require("hydronium_ink")
local oklab = require("hydronium_oklab_utils")
local logo = require("create.ui.logo")

local M = {}

M.CHAR_MS = 30
M.FLASH_MS = 150
M.HOLD_MS = 500
M.FADE_MS = 400
M.BURST_MS = 5000

M.REACTIONS = {
  { acid = "HA", base = "A-", u_base = "A⁻" },
  { acid = "HCl", base = "Cl-", u_base = "Cl⁻" },
  { acid = "HNO3", u_acid = "HNO₃", base = "NO3-", u_base = "NO₃⁻" },
  { acid = "H2SO4", u_acid = "H₂SO₄", base = "HSO4-", u_base = "HSO₄⁻" },
  { acid = "H2CO3", u_acid = "H₂CO₃", base = "HCO3-", u_base = "HCO₃⁻" },
  { acid = "NH4+", u_acid = "NH₄⁺", base = "NH3", u_base = "NH₃" },
  { acid = "CH3COOH", u_acid = "CH₃COOH", base = "CH3COO-", u_base = "CH₃COO⁻" },
  { acid = "Peptide-COOH", base = "Peptide-COO-", u_base = "Peptide-COO⁻" },
}

local function chars_of(s)
  local out = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
  return out
end

--- The reaction as a flat list of `{ ch, role }` cells.
--- Roles: acid, water, transfer (the arrow), base, hydronium, plus (" + ").
function M.cells(index, ascii)
  local r = M.REACTIONS[index] or M.REACTIONS[1]
  local parts = {
    { (not ascii and r.u_acid) or r.acid, "acid" },
    { " + ", "plus" },
    { ascii and "H2O" or "H₂O", "water" },
    { ascii and " -> " or " → ", "transfer" },
    { (not ascii and r.u_base) or r.base, "base" },
    { " + ", "plus" },
    { ascii and "H3O+" or "H₃O⁺", "hydronium" },
  }
  local cells = {}
  for _, part in ipairs(parts) do
    for _, ch in ipairs(chars_of(part[1])) do cells[#cells + 1] = { ch = ch, role = part[2] } end
  end
  return cells
end

--- Display width every reaction is laid out in: the widest one's.
function M.width(ascii)
  local widest = 0
  for i in ipairs(M.REACTIONS) do widest = math.max(widest, #M.cells(i, ascii)) end
  return widest
end

--- Key moments for reaction `index`.
--- @return { lit_at: number, settle_at: number, faded_at: number }
function M.timeline(index, ascii)
  local n = #M.cells(index, ascii)
  local lit_at = (n - 4) * M.CHAR_MS -- H₃O⁺ is always the last four cells
  local settle_at = (n - 1) * M.CHAR_MS + M.FLASH_MS
  return { lit_at = lit_at, settle_at = settle_at, faded_at = settle_at + M.HOLD_MS + M.FADE_MS }
end

--- A time far enough along that everything has settled (reduced motion,
--- skipped intro, non-interactive hosts).
function M.final_time(index, ascii)
  return M.timeline(index, ascii).faded_at + M.BURST_MS
end

--- A random reaction index for this run. Seeded from the clock without
--- touching the global `math.random` state.
function M.pick(seed)
  seed = seed or (os.time() * 1000 + math.floor((os.clock() % 1) * 1000))
  return (math.floor(seed) % #M.REACTIONS) + 1
end

local ROLE_HUE = { acid = 55, water = 145, base = 250, transfer = nil, plus = nil }
local ROLE_ANSI = { acid = "yellow", water = "green", base = "blue" }
local GRAY_L = 0.52

local function role_color(role, fade)
  local hue = ROLE_HUE[role]
  if not hue then
    -- Operators and the arrow: white settling to gray with the reactants.
    local l = 0.92 - (0.92 - GRAY_L) * fade
    local c = oklab.oklch(l, 0, 0)
    return ink.byProfile({ truecolor = c, ansi256 = c, ansi16 = fade >= 0.5 and "brightBlack" or "white" })
  end
  local c = oklab.oklch(0.74 - (0.74 - GRAY_L) * fade, 0.16 * (1 - fade), hue)
  return ink.byProfile({ truecolor = c, ansi256 = c, ansi16 = fade >= 0.5 and "brightBlack" or ROLE_ANSI[role] })
end

local FLASH = ink.byProfile({ truecolor = oklab.hex("#ffffff"), ansi256 = oklab.hex("#ffffff"), ansi16 = "brightWhite" })

--- Text props for cell `i` of `cells` at time `t`.
local function cell_props(cells, i, t, timeline)
  local cell = cells[i]
  local revealed = (i - 1) * M.CHAR_MS
  if t < revealed then return { color = "brightBlack", dimColor = true } end
  if t < revealed + M.FLASH_MS then return { color = FLASH, bold = true } end
  if cell.role == "hydronium" then
    -- Settled on the pH gradient; a small travelling shimmer while the fizz
    -- bursts, decaying to still.
    local since = t - timeline.lit_at
    local phase = 0
    if since < M.BURST_MS then
      -- Kept in [0, amplitude]: a negative phase would wrap through `% 1`
      -- and jump H to the far (violet) end of the gradient.
      local amplitude = 0.18 * (1 - since / M.BURST_MS)
      phase = amplitude * (0.5 + 0.5 * math.sin(2 * math.pi * since / 900))
    end
    local k = i - (#cells - 4)
    return { color = logo.gradient_color(k, 4, phase), bold = k == 1 or k == 3 }
  end
  local fade = 0
  local fade_start = timeline.settle_at + M.HOLD_MS
  if t >= fade_start then fade = math.min(1, (t - fade_start) / M.FADE_MS) end
  return { color = role_color(cell.role, fade), dimColor = fade >= 1 }
end

--- The reaction line, exactly as wide as this reaction (or just H₃O⁺ when
--- `compact`), so centering it centers the visible text.
--- @param props { index?: integer, time?: number, ascii?: boolean, compact?: boolean }
function M.render(props)
  props = props or {}
  local index = props.index or 1
  local cells = M.cells(index, props.ascii)
  local timeline = M.timeline(index, props.ascii)
  local t = math.max(0, props.time or 0)
  local first = props.compact and (#cells - 3) or 1
  local elements = {}
  for i = first, #cells do
    local text_props = cell_props(cells, i, t, timeline)
    text_props.key = i
    elements[#elements + 1] = H.h(ink.Text, text_props, cells[i].ch)
  end
  return H.h(ink.Box, { flexDirection = "row", width = #cells - first + 1, flexShrink = 0 }, elements)
end

return M
