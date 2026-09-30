--[[
  hydronium_create.ui.logo -- the wizard's one-line header "diorama":
  inline H3O+ "formula lettering" (bold H and O with the real Unicode
  subscript "3" and superscript "+" riding right next to them, so it reads
  as H₃O⁺ on a single line -- no multi-row block art), the
  "hydronium/create app vX.Y.Z" wordmark, a flex-expanding gap
  (`ink.Spacer`), and a right-aligned update-status indicator, plus a
  scattered field of sparkly bubbles across the row above it.

  Pure `render(props)`, no internal state -- wizard_app.lua owns the
  useAnimation ticker that drives the one-time startup sweep (`sweep`) and
  the continuous bubble ticker (`frame`).

  COLOR PROFILE: a pH-scale gradient (red -> amber -> green -> blue ->
  violet) is swept across H₃O⁺ and the closing rule. Every hue is handed to
  Ink as a real hydronium_oklab_utils.oklch value, which hydronium_ink.color
  already lowers to ansi256/ansi16 automatically at paint time (see
  ink/REGISTRY_README.md's "Color capability" section) -- no manual
  quantization needed here. What DOES need to be explicit is "none"
  (NO_COLOR): a plain oklch color paints identically regardless of profile
  unless it goes through `ink.byProfile`, which is what makes the `none`
  entry (omitted below, so it strips to no color -- see REGISTRY_README's
  "Color profile" fallback-chain doc) actually take effect. ansi16 gets its
  own named-palette entry per hue rather than inheriting the oklch (ansi16's
  16 slots are THEME-remapped by the user's terminal, so an assumed RGB for
  one is false precision -- same reasoning as cli/src/ui/search_bar.lua's
  own ansi16 path, see that file's header comment).

  RESPONSIVE: breakpoints by column width --
    >= 80: full "H₃O⁺ · hydronium/create app vX.Y.Z" line, bubbles above,
           update status as icon + full label ("Checking for updates…")
    64-79: same line and bubbles, status icon + short label ("vX.Y.Z")
    40-63: compact "H₃O⁺ · hydronium/create vX.Y.Z", no bubbles, status
           icon only
    < 40 : wordmark only, no symbol and no status
]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local oklab = require("hydronium_oklab_utils")

local M = {}

-- pH-scale stops: acidic red -> amber -> neutral green -> alkaline blue -> violet.
-- Hues chosen to read clearly as that progression in OKLCH, not picked to
-- match any particular indicator dye's exact real-world hue.
local PH_STOPS = {
  { oklch = oklab.oklch(0.62, 0.19, 25),  ansi16 = "red" },
  { oklch = oklab.oklch(0.75, 0.15, 70),  ansi16 = "yellow" },
  { oklch = oklab.oklch(0.72, 0.17, 145), ansi16 = "green" },
  { oklch = oklab.oklch(0.60, 0.15, 250), ansi16 = "blue" },
  { oklch = oklab.oklch(0.62, 0.16, 305), ansi16 = "magenta" },
}

--- Picks a pH-scale stop for column index `i` of `total` (1-based),
--- optionally rotated by a 0..1 `phase` (the startup sweep's progress) so
--- the gradient visibly travels left-to-right across the glyph once.
local function stop_at(i, total, phase)
  phase = phase or 0
  local t = ((i - 1) / math.max(1, total - 1) + phase) % 1
  local scaled = t * (#PH_STOPS - 1)
  local index = math.floor(scaled) + 1
  if index >= #PH_STOPS then return PH_STOPS[#PH_STOPS] end
  return PH_STOPS[index]
end

local function gradient_color(i, total, phase)
  local stop = stop_at(i, total, phase)
  return ink.byProfile({ truecolor = stop.oklch, ansi256 = stop.oklch, ansi16 = stop.ansi16 })
end
-- Exposed so ui/bubbles.lua's "explode into the pH sequence" flash uses
-- the exact same stops/positions this header does, rather than a second,
-- possibly-drifting copy of the same table.
M.gradient_color = gradient_color

--- @param props { sweep?: number 0..1 progress of the one-time startup
---   gradient sweep, or nil once it's finished/skipped (a static gradient
---   is still drawn -- it just stops animating). version: string. columns:
---   integer, current terminal width, for the responsive tiers above.
---   update_status?: { available: boolean, latest?: string } -- see
---   wizard_app.lua's own comment on where this REALLY comes from (a
---   local, honest comparison -- there is no registry network check
---   implemented here; see that file for exactly what is and isn't real). }
--- @return any element
function M.render(props)
  props = props or {}
  local columns = props.columns or 80
  local version = props.version or "0.0.0"
  local sweep = props.sweep -- nil once finished; a live 0..1 value while sweeping
  local phase = sweep or 0

  if columns < 40 then
    return hydronium.h(ink.Text, { key = "wordmark", color = "brightBlack" }, "hydronium · create  v" .. version)
  end

  -- H₃O⁺, INLINE: four cells (H, ₃, O, ⁺), each its own gradient-position
  -- color -- bold for the two real letters, normal weight for the real
  -- Unicode subscript/superscript so they read visually smaller without
  -- needing second row of block art.
  local formula_cells = {
    { ch = "H", bold = true },
    { ch = "\226\130\131", bold = false }, -- ₃
    { ch = "O", bold = true },
    { ch = "\226\129\186", bold = false }, -- ⁺
  }
  local formula = {}
  for i, cell in ipairs(formula_cells) do
    formula[i] = hydronium.h(ink.Text, { key = "f" .. i, color = gradient_color(i, #formula_cells, phase), bold = cell.bold }, cell.ch)
  end

  local wordmark = columns < 64
    and hydronium.h(ink.Text, { key = "wordmark", color = "brightBlack" }, " · hydronium/create v" .. version)
    or hydronium.h(ink.Text, { key = "wordmark", color = "brightBlack" },
      " \194\183 hydronium/create app v" .. version) -- " · hydronium/create app vX.Y.Z"

  return hydronium.h(ink.Box, { key = "diorama", flexDirection = "row" },
    formula, wordmark,
    hydronium.h(ink.Spacer, { key = "spacer" }),
    M.render_status(props.update_status, columns, props.frame))
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Badge colours were picked by APCA, not by eye: white on the green scores
-- Lc -76, near-black on the yellow Lc 75 (oklab.lc), white on the blue
-- checking badge likewise clears Lc 60. ansi16 falls back to the theme's own
-- palette slots; "none" strips colour and keeps the badge readable as an
-- inverse block.
local WHITE = ink.byProfile({ truecolor = oklab.hex("#ffffff"), ansi256 = oklab.hex("#ffffff"), ansi16 = "brightWhite" })
local BADGE = {
  checking = {
    background = ink.byProfile({ truecolor = oklab.oklch(0.52, 0.15, 250), ansi256 = oklab.oklch(0.52, 0.15, 250), ansi16 = "blue" }),
    color = WHITE,
    label_color = ink.byProfile({ truecolor = oklab.oklch(0.72, 0.13, 250), ansi256 = oklab.oklch(0.72, 0.13, 250), ansi16 = "brightBlue" }),
  },
  current = {
    glyph = "✓",
    background = ink.byProfile({ truecolor = oklab.oklch(0.55, 0.15, 150), ansi256 = oklab.oklch(0.55, 0.15, 150), ansi16 = "green" }),
    color = WHITE,
    label_color = ink.byProfile({ truecolor = oklab.oklch(0.72, 0.15, 150), ansi256 = oklab.oklch(0.72, 0.15, 150), ansi16 = "green" }),
  },
  available = {
    glyph = "!",
    background = ink.byProfile({ truecolor = oklab.oklch(0.84, 0.16, 90), ansi256 = oklab.oklch(0.84, 0.16, 90), ansi16 = "yellow" }),
    color = ink.byProfile({ truecolor = oklab.hex("#111111"), ansi256 = oklab.hex("#111111"), ansi16 = "black" }),
    label_color = ink.byProfile({ truecolor = oklab.oklch(0.84, 0.16, 90), ansi256 = oklab.oklch(0.84, 0.16, 90), ansi16 = "yellow" }),
  },
}
local INVERSE_WITHOUT_COLOR = ink.byProfile({ none = true })

local function H_row(label, badge, glyph)
  return hydronium.h(ink.Box, { key = "status", flexDirection = "row", flexShrink = 0 },
    label ~= "" and hydronium.h(ink.Text, { key = "label", color = badge.label_color }, label .. " ") or nil,
    hydronium.h(ink.Text, { key = "badge", backgroundColor = badge.background, color = badge.color,
      bold = true, inverse = INVERSE_WITHOUT_COLOR }, " " .. glyph .. " "))
end

local function status_state(status)
  return status.state or (status.available and "available" or "current")
end

--- The label for `status` at breakpoint `tier` (80 full, 64 short, else none).
local function status_label(status, tier)
  local state = status_state(status)
  if state == "checking" then return tier >= 80 and "Checking for updates…" or tier >= 64 and "Checking…" or "" end
  if state == "available" then
    local latest = "v" .. tostring(status.latest or "?")
    return tier >= 80 and ("Update available " .. latest) or tier >= 64 and latest or ""
  end
  return tier >= 80 and "Up to date" or ""
end

--- Cells the indicator occupies at `tier` (0 when there is no status).
function M.status_width(status, tier)
  if not status or not BADGE[status_state(status)] then return 0 end
  local label = status_label(status, tier)
  local cells = 0
  for _ in label:gmatch("[%z\1-\127\194-\244][\128-\191]*") do cells = cells + 1 end
  return (cells > 0 and cells + 1 or 0) + 3
end

--- Update-status indicator: a label, then a 3-cell badge that is always the
--- rightmost thing on the line, so the eye finds the state in one place:
---   checking   white braille spinner on blue
---   available  ! on yellow   + "Update available vX" (>=80) / "vX" (>=64)
---   current    ✓ on green    + "Up to date" (>=80)
--- Below 64 only the badge remains. nil status (unknown: offline, disabled,
--- no data) renders nothing -- never a claim without data.
--- Accepts the older `{ available = bool }` shape too.
--- @param status? { state?: "checking"|"available"|"current", available?: boolean, latest?: string }
--- @param tier integer breakpoint: 80 full label, 64 short label, lower badge only
--- @param frame? integer spinner frame
function M.render_status(status, tier, frame)
  if not status then return nil end
  local state = status_state(status)
  local badge = BADGE[state]
  if not badge then return nil end
  local glyph = state == "checking" and SPINNER[((frame or 0) % #SPINNER) + 1] or badge.glyph
  local label = status_label(status, tier)
  return H_row(label, badge, glyph)
end

--- Exposed so bubbles.lua (and stories/snapshots) can size their field
--- without duplicating this constant.
M.WIDE_HEIGHT = 1

--- The CLOSING pH-gradient rule: a single full-width line of "━", colored
--- with the same sweep this header's block art uses (statically, phase 0
--- -- there is no animated sweep at this point in the form's life, only a
--- settled gradient). This is what actually closes the form, NOT a second
--- copy of the block logo -- a full re-render of the H3O+ art here would
--- read as "another header," not a closing divider.
--- @param props { columns: integer }
--- @return any element
function M.render_rule(props)
  props = props or {}
  local columns = math.max(1, props.columns or 80)
  local cells = {}
  for i = 1, columns do
    cells[i] = hydronium.h(ink.Text, { key = i, color = gradient_color(i, columns, 0) }, "\226\148\129") -- ━
  end
  return hydronium.h(ink.Box, { flexDirection = "row" }, cells)
end

return M
