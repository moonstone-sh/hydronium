-- Perceptual color values and conversions. Public sRGB channels are bytes;
-- internal conversion stays in the 0..1 encoded sRGB domain.
local M = {}

---@class hydronium_oklab_utils.Color
---@field space "srgb"|"oklab"|"oklch"
---@field r? number sRGB byte channel, 0..255.
---@field g? number sRGB byte channel, 0..255.
---@field b? number sRGB byte channel, 0..255; also OKLab's b axis when space="oklab".
---@field l? number OKLab/OKLCH lightness.
---@field a? number OKLab a axis.
---@field c? number OKLCH chroma.
---@field h? number OKLCH hue in degrees.

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function finite(x, name)
  if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then
    error("hydronium_oklab_utils: " .. name .. " must be a finite number", 3)
  end
  return x
end
local function linear(v)
  return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
end
local function encoded(v)
  return v <= 0.0031308 and 12.92 * v or 1.055 * v ^ (1 / 2.4) - 0.055
end
local function signed_cuberoot(v) return v < 0 and -(-v) ^ (1 / 3) or v ^ (1 / 3) end

function M.srgb(r, g, b)
  return { space = "srgb", r = clamp(finite(r, "r"), 0, 255), g = clamp(finite(g, "g"), 0, 255), b = clamp(finite(b, "b"), 0, 255) }
end

function M.hex(value)
  if type(value) ~= "string" then error("hydronium_oklab_utils: hex expects '#RRGGBB'", 2) end
  local r, g, b = value:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then error("hydronium_oklab_utils: hex expects opaque '#RRGGBB'", 2) end
  return M.srgb(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

function M.oklab(l, a, b)
  return { space = "oklab", l = finite(l, "l"), a = finite(a, "a"), b = finite(b, "b") }
end

function M.oklch(l, c, h)
  return { space = "oklch", l = finite(l, "l"), c = math.max(0, finite(c, "c")), h = finite(h, "h") % 360 }
end

function M.to_oklab(value)
  if type(value) ~= "table" then error("hydronium_oklab_utils: expected a color value", 2) end
  if value.space == "oklab" then return M.oklab(value.l, value.a, value.b) end
  if value.space == "oklch" then
    local angle = value.h * math.pi / 180
    return M.oklab(value.l, value.c * math.cos(angle), value.c * math.sin(angle))
  end
  if value.space == "srgb" then
    local r, g, b = linear(value.r / 255), linear(value.g / 255), linear(value.b / 255)
    local l = signed_cuberoot(0.4122214708*r + 0.5363325363*g + 0.0514459929*b)
    local m = signed_cuberoot(0.2119034982*r + 0.6806995451*g + 0.1073969566*b)
    local s = signed_cuberoot(0.0883024619*r + 0.2817188376*g + 0.6299787005*b)
    return M.oklab(0.2104542553*l + 0.7936177850*m - 0.0040720468*s, 1.9779984951*l - 2.4285922050*m + 0.4505937099*s, 0.0259040371*l + 0.7827717662*m - 0.8086757660*s)
  end
  error("hydronium_oklab_utils: unknown color space '" .. tostring(value.space) .. "'", 2)
end

function M.to_oklch(value)
  local lab = M.to_oklab(value)
  local c = math.sqrt(lab.a * lab.a + lab.b * lab.b)
  return M.oklch(lab.l, c, c == 0 and 0 or math.atan2(lab.b, lab.a) * 180 / math.pi)
end

local function raw_srgb(lab)
  local l = lab.l + 0.3963377774*lab.a + 0.2158037573*lab.b
  local m = lab.l - 0.1055613458*lab.a - 0.0638541728*lab.b
  local s = lab.l - 0.0894841775*lab.a - 1.2914855480*lab.b
  l, m, s = l*l*l, m*m*m, s*s*s
  return encoded(4.0767416621*l - 3.3077115913*m + 0.2309699292*s), encoded(-1.2684380046*l + 2.6097574011*m - 0.3413193965*s), encoded(-0.0041960863*l - 0.7034186147*m + 1.7076147010*s)
end
local function in_gamut(r, g, b) return r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1 end

function M.to_srgb(value)
  if value.space == "srgb" then return M.srgb(value.r, value.g, value.b) end
  local lch = M.to_oklch(value)
  local lab = M.to_oklab(lch)
  local r, g, b = raw_srgb(lab)
  -- Preserve lightness and hue, reducing chroma only when needed. This is
  -- vastly less surprising than blindly clipping three encoded channels.
  if not in_gamut(r, g, b) then
    local low, high = 0, lch.c
    for _ = 1, 20 do
      local mid = (low + high) / 2
      local candidate = M.to_oklab(M.oklch(lch.l, mid, lch.h))
      local cr, cg, cb = raw_srgb(candidate)
      if in_gamut(cr, cg, cb) then low = mid else high = mid end
    end
    r, g, b = raw_srgb(M.to_oklab(M.oklch(lch.l, low, lch.h)))
  end
  return M.srgb(math.floor(clamp(r, 0, 1) * 255 + 0.5), math.floor(clamp(g, 0, 1) * 255 + 0.5), math.floor(clamp(b, 0, 1) * 255 + 0.5))
end

function M.mix(a, b, amount)
  amount = clamp(finite(amount, "amount"), 0, 1)
  a, b = M.to_oklab(a), M.to_oklab(b)
  return M.oklab(a.l + (b.l-a.l)*amount, a.a + (b.a-a.a)*amount, a.b + (b.b-a.b)*amount)
end

function M.contrast(a, b)
  local function luminance(c)
    c = M.to_srgb(c)
    local r, g, bl = linear(c.r/255), linear(c.g/255), linear(c.b/255)
    return 0.2126*r + 0.7152*g + 0.0722*bl
  end
  local x, y = luminance(a), luminance(b)
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end

-- APCA-W3 (0.0.98G-4g constants -- the version whose reference numbers are
-- checked in tests/core/oklab_utils_spec.lua, e.g. #888-on-#fff = Lc 63.1).
-- WCAG 2's ratio above is the wrong instrument for small/bold UI text and
-- for dark backgrounds specifically -- it is a mid-tone photopic model,
-- known and documented by APCA's own authors to be miscalibrated exactly
-- there. APCA is signed rather than a bare ratio: positive means dark text
-- on a light background, negative means light text on a dark one.
local APCA = {
  trc = 2.4,
  rco = 0.2126729, gco = 0.7151522, bco = 0.0721750,
  norm_bg = 0.56, norm_txt = 0.57, rev_txt = 0.62, rev_bg = 0.65,
  black_threshold = 0.022, black_clamp = 1.414,
  scale = 1.14, low_offset = 0.027, delta_y_min = 0.0005,
}

-- APCA's own screen luminance (not CIE Y, not OKLab's L) of the FINAL,
-- gamut-mapped, rounded 8-bit sRGB `to_srgb` actually produces -- not of
-- the requested color value. This is deliberate: an out-of-gamut OKLCH
-- input (chroma reduced by to_srgb's own binary search to fit sRGB) scores
-- exactly what a truecolor terminal or browser really paints, never a
-- hypothetical wide-gamut color nothing here can display.
local function apca_y(value)
  local srgb = M.to_srgb(value)
  return APCA.rco * (srgb.r / 255) ^ APCA.trc
    + APCA.gco * (srgb.g / 255) ^ APCA.trc
    + APCA.bco * (srgb.b / 255) ^ APCA.trc
end

local function apca_soft_black(y)
  if y > APCA.black_threshold then return y end
  return y + (APCA.black_threshold - y) ^ APCA.black_clamp
end

--- APCA-W3 (0.0.98G-4g) lightness contrast of `text` against `bg`, evaluated
--- on the same final 8-bit sRGB `to_srgb` produces (gamut mapping and byte
--- rounding included) -- i.e. what a truecolor terminal or browser actually
--- paints, not the requested OKLCH point. Prefer this over `contrast()`'s
--- WCAG 2 ratio for small/bold text and for dark backgrounds, where WCAG 2
--- is known to be miscalibrated. Signed: positive is dark text on a light
--- background, negative is light text on a dark one -- most callers want
--- the magnitude (`math.abs`).
--- @param text hydronium_oklab_utils.Color
--- @param bg hydronium_oklab_utils.Color
--- @return number lc
function M.lc(text, bg)
  local y_txt = apca_soft_black(apca_y(text))
  local y_bg = apca_soft_black(apca_y(bg))
  if math.abs(y_bg - y_txt) < APCA.delta_y_min then return 0.0 end
  if y_bg > y_txt then
    local sapc = (y_bg ^ APCA.norm_bg - y_txt ^ APCA.norm_txt) * APCA.scale
    return (sapc < APCA.low_offset and 0.0 or sapc - APCA.low_offset) * 100
  else
    local sapc = (y_bg ^ APCA.rev_bg - y_txt ^ APCA.rev_txt) * APCA.scale
    return (sapc > -APCA.low_offset and 0.0 or sapc + APCA.low_offset) * 100
  end
end

--- Returns whichever of `opts.candidates` (default near-black / near-white,
--- so this works as a generic "pick legible text" helper for any
--- background) is more legible on `bg`, judged by |lc| (APCA-W3).
--- @param bg hydronium_oklab_utils.Color
--- @param opts? { candidates?: hydronium_oklab_utils.Color[] }
--- @return hydronium_oklab_utils.Color color, number lc
function M.readable_on(bg, opts)
  opts = opts or {}
  local candidates = opts.candidates or { M.hex("#111111"), M.hex("#f5f5f5") }
  local best, best_lc = candidates[1], M.lc(candidates[1], bg)
  for i = 2, #candidates do
    local lc = M.lc(candidates[i], bg)
    if math.abs(lc) > math.abs(best_lc) then best, best_lc = candidates[i], lc end
  end
  return best, best_lc
end

--- Moves `fg`'s OKLCH lightness -- and, only if the gamut boundary still
--- can't reach `target`, its chroma too -- toward whichever of black/white
--- raises its contrast against `bg`, stopping as soon as `target` is met.
--- Hue is always preserved; chroma is shed only as a last resort, and only
--- as much as needed. `opts.metric` selects "apca" (default, matched
--- against |lc|) or "wcag" (matched against `contrast()`'s ratio). Returns
--- the best achievable color and its score even when `target` is out of
--- reach at any lightness/chroma.
--- @param fg hydronium_oklab_utils.Color
--- @param bg hydronium_oklab_utils.Color
--- @param target number
--- @param opts? { metric?: "apca"|"wcag" }
--- @return hydronium_oklab_utils.Color color, number achieved
function M.ensure_contrast(fg, bg, target, opts)
  opts = opts or {}
  local metric = opts.metric or "apca"
  if metric ~= "apca" and metric ~= "wcag" then
    error("hydronium_oklab_utils: unknown metric '" .. tostring(metric) .. "'", 2)
  end
  local function score(color)
    if metric == "wcag" then return M.contrast(color, bg) end
    return math.abs(M.lc(color, bg))
  end

  local lch = M.to_oklch(fg)
  local function at(l, c) return M.oklch(clamp(l, 0, 1), math.max(0, c), lch.h) end

  local start_score = score(at(lch.l, lch.c))
  if start_score >= target then return at(lch.l, lch.c), start_score end

  -- Try both directions (toward black, toward white); keep whichever
  -- endpoint -- at the SAME chroma as `fg` -- scores higher.
  local best_l, best_score = lch.l, start_score
  for _, endpoint in ipairs({ 0, 1 }) do
    local s = score(at(endpoint, lch.c))
    if s > best_score then best_l, best_score = endpoint, s end
  end

  if best_score < target then
    -- Even full black/white at this chroma can't reach it. Desaturating at
    -- that same extreme can only help (or do nothing) when the gamut
    -- mapping toward that corner was chroma-limited.
    local achromatic = at(best_l, 0)
    local achromatic_score = score(achromatic)
    if achromatic_score <= best_score then
      return at(best_l, lch.c), best_score
    end
    if achromatic_score < target then
      -- Zero chroma is the best this lightness can do and it still misses
      -- the target: report it, since it's strictly better than the
      -- original chroma.
      return achromatic, achromatic_score
    end
    -- Zero chroma clears the target; binary-search for the LEAST
    -- desaturation that still does, so hue intent survives as much as the
    -- target allows.
    local low, high = 0, lch.c
    for _ = 1, 24 do
      local mid = (low + high) / 2
      if score(at(best_l, mid)) >= target then low = mid else high = mid end
    end
    return at(best_l, low), score(at(best_l, low))
  end

  -- Binary-search lightness between the unchanged start and whichever
  -- endpoint reaches the target, stopping as soon as it's met so the
  -- result stays as close to the original color as the target allows.
  local from, to = lch.l, best_l
  local result, result_score = at(to, lch.c), best_score
  for _ = 1, 30 do
    local mid = (from + to) / 2
    local s = score(at(mid, lch.c))
    if s >= target then
      result, result_score = at(mid, lch.c), s
      to = mid
    else
      from = mid
    end
  end
  return result, result_score
end

return M
