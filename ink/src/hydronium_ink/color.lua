-- Terminal-color boundary. Palette names deliberately remain palette
-- references; absolute sRGB/OKLCH values are lowered only at paint time.
local oklab = require("hydronium_oklab_utils")

local M = {}

local PALETTE = {
  black = 0, red = 1, green = 2, yellow = 3, blue = 4, magenta = 5, cyan = 6, white = 7,
  brightBlack = 8, brightRed = 9, brightGreen = 10, brightYellow = 11,
  brightBlue = 12, brightMagenta = 13, brightCyan = 14, brightWhite = 15,
}
local ANSI16_RGB = {
  { 0, 0, 0 }, { 205, 49, 49 }, { 13, 188, 121 }, { 229, 229, 16 },
  { 36, 114, 200 }, { 188, 63, 188 }, { 17, 168, 205 }, { 229, 229, 229 },
  { 102, 102, 102 }, { 241, 76, 76 }, { 35, 209, 139 }, { 245, 245, 67 },
  { 59, 142, 234 }, { 214, 112, 214 }, { 41, 184, 219 }, { 255, 255, 255 },
}

local function clamp(x, low, high) return math.max(low, math.min(high, x)) end
--- @param value? "auto"|"truecolor"|"ansi256"|"ansi16"
--- @param getenv? fun(name: string): string|nil Injected for testing --
---   see `M.profile`'s own doc comment for why this seam exists (a Lua
---   process cannot mutate its own real environment).
local function term_capability(value, getenv)
  if value == "truecolor" or value == "ansi256" or value == "ansi16" then return value end
  if value ~= nil and value ~= "auto" then error("hydronium_ink: unsupported capability '" .. tostring(value) .. "'", 3) end
  local env = getenv or os.getenv
  local colorterm = (env("COLORTERM") or ""):lower()
  if colorterm:find("truecolor", 1, true) or colorterm:find("24bit", 1, true) then return "truecolor" end
  if (env("TERM") or ""):find("256color", 1, true) then return "ansi256" end
  return "ansi16"
end
M.capability = term_capability

--[[
  COLOR PROFILE -- a strict superset of `M.capability` above, adding
  "none" for "emit no color at all" (NO_COLOR, https://no-color.org, or an
  explicit `FORCE_COLOR=0`). Deliberately kept SEPARATE from `capability`,
  not a replacement for it: `capability` is the ANSI ENCODING DEPTH
  `M.sgr`/`M.lower` quantize an already-chosen color down to, and stays
  exactly as it was (3 values, no "none") so every existing caller and
  every plain `color = "#rrggbb"`/`color = "red"` prop keeps rendering
  exactly as before, in whatever depth the terminal supports, even under
  NO_COLOR -- that is the user's own decided design stance (see
  hydronium_ink.hooks.useColorProfile's doc comment): ink EXPOSES the
  profile and lets a component choose what to do about it (`M.by_profile`
  below, or nothing at all) rather than silently stripping every color
  itself. `M.profile` is the plain, non-reactive function
  `hydronium_ink.hooks.useColorProfile` and `ink.colorProfile` are built
  on; `hydronium_ink.session` seeds a session's reactive value from it
  once at creation, overridable via `SessionOptions.colorProfile` (see
  session.lua) exactly like `SessionOptions.color` already overrides
  `capability`.
--]]
M.PROFILES = { "truecolor", "ansi256", "ansi16", "none" }
--- Richer (smaller) to plainer (larger) rank, used by `M.resolve_by_profile`
--- to find "the next richer defined entry" when the exact profile is
--- missing from a `M.by_profile` table.
M.PROFILE_RANK = { truecolor = 1, ansi256 = 2, ansi16 = 3, none = 4 }

--- @param value? "auto"|"truecolor"|"ansi256"|"ansi16"|"none" Explicit
---   override; "auto" (the default) detects from the environment.
--- @param getenv? fun(name: string): string|nil Injected for testing; a Lua
---   process cannot mutate its own real environment (`os.getenv` has no
---   companion `os.setenv` in stock Lua/LuaJIT), so without this seam
---   NO_COLOR/FORCE_COLOR detection could only be exercised by shelling out
---   -- the exact same problem `hydronium_ink.host.terminal`'s own
---   `autoHyperlinkCapability(getenv)` solves the same way. Defaults to
---   `os.getenv`.
--- @return "truecolor"|"ansi256"|"ansi16"|"none"
function M.profile(value, getenv)
  if value == "truecolor" or value == "ansi256" or value == "ansi16" or value == "none" then return value end
  if value ~= nil and value ~= "auto" then
    error("hydronium_ink: unsupported color profile '" .. tostring(value) .. "'", 3)
  end
  local env = getenv or os.getenv
  -- FORCE_COLOR is checked before NO_COLOR: it is the more specific,
  -- explicit request (the convention `chalk`/`supports-color` and friends
  -- use), so a caller that sets both -- CI harnesses forcing color output
  -- despite a NO_COLOR left over from some other tool -- gets what they
  -- explicitly asked for rather than the more general opt-out silently
  -- winning.
  local force = env("FORCE_COLOR")
  if force ~= nil and force ~= "" then
    if force == "0" then return "none" end
    if force == "1" then return "ansi16" end
    if force == "2" then return "ansi256" end
    return "truecolor" -- "3", "true", or any other non-empty, non-numeric value.
  end
  -- NO_COLOR (https://no-color.org): "when present (regardless of its
  -- value)" -- an empty NO_COLOR="" still means "no color", so this checks
  -- presence via a second return value from getenv, not truthiness of the
  -- string itself (an empty string is truthy in Lua anyway, but this
  -- spells out the actual rule rather than relying on that coincidence).
  if env("NO_COLOR") ~= nil then return "none" end
  return term_capability("auto", env)
end

--- @class hydronium_ink.ByProfile
--- @field __hydronium_ink_by_profile true
--- @field entries table<"truecolor"|"ansi256"|"ansi16"|"none", any>

--- Marks a prop value (a color, or any other Text/Box style prop --
--- `inverse`, `bold`, `dimColor`, etc.) as PROFILE-DEPENDENT: resolved not
--- to one fixed value but to whichever of `entries` applies to the color
--- profile actually in effect when it paints (see
--- `hydronium_ink.host.terminal`'s `resolveStyleValue`, the one place
--- every Text/Box style prop is run through this). `ink.byProfile` and
--- `ink.adaptive` (hydronium_ink/init.lua) are the same function under two
--- names -- `adaptive` reads better on a single color value
--- (`color = ink.adaptive({ truecolor = oklch(...), ansi16 = "cyan" })`),
--- `byProfile` on a whole style dict passed prop-by-prop.
---
--- A value passed for `entries` other than one of `M.PROFILES` errors
--- immediately -- a typo'd profile name (e.g. "true_color") would
--- otherwise silently never match anything, which is exactly the class of
--- silent-failure bug this codebase's other modules go out of their way
--- to avoid (see e.g. session.lua's own `evt.stop()` doc comment).
--- @param entries table<string, any>
--- @return hydronium_ink.ByProfile
function M.by_profile(entries)
  if type(entries) ~= "table" then
    error("hydronium_ink: by_profile expects a table keyed by color profile", 3)
  end
  for name in pairs(entries) do
    if M.PROFILE_RANK[name] == nil then
      error("hydronium_ink: by_profile: unknown color profile '" .. tostring(name)
        .. "' (expected truecolor, ansi256, ansi16, or none)", 3)
    end
  end
  return { __hydronium_ink_by_profile = true, entries = entries }
end

--- @param value any
--- @return boolean
function M.is_by_profile(value)
  return type(value) == "table" and value.__hydronium_ink_by_profile == true
end

--- Resolves a `M.by_profile(...)` value for `profile`.
---
--- FALLBACK CHAIN: an exact `entries[profile]` wins outright. Missing
--- that, this looks for the NEXT RICHER profile that IS defined (e.g.
--- `profile == "ansi16"` with only `truecolor` and `none` given uses
--- `truecolor`, not `none` -- "richer" always wins over "plainer" when the
--- exact entry is absent) and returns that entry AS GIVEN, unquantized --
--- deliberately not pre-lowered here. A color value returned this way
--- still passes through `M.resolve`/`M.lower`/`M.sgr`'s own existing
--- capability-based quantization exactly like any other color prop does,
--- which IS the "auto-lower" (an ansi16-nearest-slot search runs on it
--- regardless of which profile's entry supplied the raw value) -- doing it
--- again here would be redundant, and would be flatly wrong for a
--- non-color style prop (`inverse`/`bold`) that has no quantization step
--- to run at all.
---
--- No entry at or above `profile` resolves to `nil, false` -- "no override
--- applies," NOT "false"/"default": the caller (`resolveStyleValue`)
--- leaves the prop untouched in that case, same as if it had never been
--- given at all.
---
--- Generic -- used for STRUCTURAL props (`inverse`/`bold`/`dimColor`/etc.),
--- which have no quantization step and so should keep inheriting a
--- richer-profile's value all the way down to "none" if that's all that
--- was given. A COLOR prop needs a different rule at "none" specifically
--- -- see `M.resolve_by_profile_color` below, which callers use for
--- `color`/`backgroundColor`/`borderColor`/etc. instead of this.
--- @param marker hydronium_ink.ByProfile
--- @param profile "truecolor"|"ansi256"|"ansi16"|"none"
--- @return any value, boolean present
function M.resolve_by_profile(marker, profile)
  local entries = marker.entries
  if entries[profile] ~= nil then return entries[profile], true end
  local profileRank = M.PROFILE_RANK[profile] or M.PROFILE_RANK.truecolor
  local bestValue, bestRank
  for name, value in pairs(entries) do
    local rank = M.PROFILE_RANK[name]
    if rank < profileRank and (bestRank == nil or rank > bestRank) then
      bestValue, bestRank = value, rank
    end
  end
  if bestRank ~= nil then return bestValue, true end
  return nil, false
end

--- Same fallback chain as `M.resolve_by_profile`, EXCEPT at `profile ==
--- "none"` with no explicit `entries.none`: rather than inheriting a
--- richer profile's real color (which would defeat NO_COLOR/an explicit
--- `colorProfile = "none"` override for exactly the props that opted in to
--- being profile-aware -- the color would still paint, in whatever ANSI
--- depth `Session:colorCapability()` happens to be, regardless of "none"),
--- this returns `nil, true`: an ACTIVE override to "no color," not "no
--- override applies." `M.resolve(nil)` is itself `nil`, so a caller that
--- always runs `if props.color ~= nil then style.fg = M.resolve(v) end`
--- (true whenever `props.color` IS a by_profile marker, since the MARKER
--- itself is never nil even when what it resolves to is) ends up setting
--- `style.fg = nil` -- an explicit strip, overriding any inherited color
--- too, not merely leaving one in place. This is this package's stated
--- default: "none" strips color, keeps inverse/bold (the latter still
--- goes through the generic `M.resolve_by_profile` above, unaffected).
--- @param marker hydronium_ink.ByProfile
--- @param profile "truecolor"|"ansi256"|"ansi16"|"none"
--- @return any value, boolean present
function M.resolve_by_profile_color(marker, profile)
  if marker.entries[profile] ~= nil then return marker.entries[profile], true end
  if profile == "none" then return nil, true end
  return M.resolve_by_profile(marker, profile)
end

function M.resolve(value)
  if value == nil or value == "default" then return nil end
  if type(value) == "string" then
    if PALETTE[value] ~= nil then return { kind = "palette", index = PALETTE[value] } end
    if value:match("^#%x%x%x%x%x%x$") then
      local rgb = oklab.hex(value)
      return { kind = "rgb", r = rgb.r, g = rgb.g, b = rgb.b }
    end
    error("hydronium_ink.color: unknown palette color or invalid hex '" .. value .. "'", 3)
  end
  if type(value) == "table" and (value.space == "srgb" or value.space == "oklab" or value.space == "oklch") then
    local rgb = oklab.to_srgb(value)
    return { kind = "rgb", r = rgb.r, g = rgb.g, b = rgb.b }
  end
  error("hydronium_ink.color: color must be a palette name, '#RRGGBB', or hydronium_oklab_utils value", 3)
end

function M.key(color)
  if not color then return "default" end
  if color.kind == "palette" then return "p" .. color.index end
  if color.kind == "index" then return "i" .. color.index end
  return "r" .. color.r .. ":" .. color.g .. ":" .. color.b
end

local function xterm256_rgb(index)
  if index < 16 then return ANSI16_RGB[index + 1] end
  if index >= 232 then
    local gray = 8 + (index - 232) * 10
    return { gray, gray, gray }
  end
  local n = index - 16
  local r, g, b = math.floor(n / 36), math.floor(n / 6) % 6, n % 6
  local levels = { 0, 95, 135, 175, 215, 255 }
  return { levels[r + 1], levels[g + 1], levels[b + 1] }
end

local function distance(a, b)
  local dr, dg, db = a.r - b[1], a.g - b[2], a.b - b[3]
  return dr*dr + dg*dg + db*db
end
local function nearest16(rgb)
  local best, bestDistance = 0, math.huge
  for i, candidate in ipairs(ANSI16_RGB) do
    local d = distance(rgb, candidate)
    if d < bestDistance then best, bestDistance = i - 1, d end
  end
  return best
end
local function nearest256(rgb)
  local best, bestDistance = 16, math.huge
  for i = 16, 255 do
    local d = distance(rgb, xterm256_rgb(i))
    if d < bestDistance then best, bestDistance = i, d end
  end
  return best
end

--- The assumed RGB for ANSI16 palette slot `index` (0-15). Exposed so
--- callers doing contrast math against a NAMED palette color (which has no
--- absolute RGB of its own -- see this file's own top comment) can use the
--- same assumed values this module already uses internally for
--- nearest-color quantization, rather than guessing their own.
--- @param index integer 0-15
--- @return { [1]: integer, [2]: integer, [3]: integer }|nil
function M.ansi16_rgb(index)
  return ANSI16_RGB[index + 1]
end

--- Projects a canonical color onto a terminal capability without encoding it
--- as ANSI. Browser frame consumers use this to preview the same gamut the
--- native terminal encoder would produce.
function M.lower(color, capability)
  if color == nil or color.kind == "palette" then return color end
  capability = term_capability(capability)
  if color.kind == "index" then
    if capability == "ansi16" then
      local rgb = xterm256_rgb(color.index)
      return { kind = "palette", index = nearest16({ r = rgb[1], g = rgb[2], b = rgb[3] }) }
    end
    return color
  end
  if capability == "ansi16" then return { kind = "palette", index = nearest16(color) } end
  if capability == "ansi256" then return { kind = "index", index = nearest256(color) } end
  return color
end

--- The actual sRGB a RESOLVED color (see `M.resolve`) will paint as once
--- lowered to `capability` -- e.g. the true 24-bit target rounded to its
--- nearest ansi256/ansi16 slot, not the color that was asked for. Exists so
--- `hydronium_oklab_utils.lc`/`ensure_contrast` can be re-checked AFTER
--- quantization: an absolute color chosen to hit a target contrast in
--- truecolor can still land on a worse-contrasting slot once nearest-color
--- search snaps it to one of only 256 or 16 entries.
---
--- `truecolor` is the identity of what `M.resolve` already computed -- by
--- the time a color has `kind == "rgb"`, `M.resolve` has already run it
--- through `hydronium_oklab_utils.to_srgb` (real gamut mapping + rounding),
--- so there is nothing further to quantize.
---
--- A `kind == "palette"` color (a named color, e.g. "blue") has no absolute
--- RGB of its own -- it renders however the user's terminal theme maps that
--- slot -- so this returns the same ASSUMED RGB (`ANSI16_RGB`/`ansi16_rgb`)
--- this module already uses internally for nearest-color quantization, at
--- every capability, not a value it can claim is actually correct.
--- @param color table|nil A value from `M.resolve` (or `M.lower`'s output).
--- @param capability? "auto"|"ansi16"|"ansi256"|"truecolor"
--- @return { r: integer, g: integer, b: integer }|nil
function M.effective_srgb(color, capability)
  if color == nil then return nil end
  local lowered = M.lower(color, capability)
  if lowered.kind == "palette" then
    local rgb = ANSI16_RGB[lowered.index + 1]
    return rgb and { r = rgb[1], g = rgb[2], b = rgb[3] } or nil
  end
  if lowered.kind == "index" then
    local rgb = xterm256_rgb(lowered.index)
    return { r = rgb[1], g = rgb[2], b = rgb[3] }
  end
  return { r = lowered.r, g = lowered.g, b = lowered.b }
end

function M.sgr(color, background, capability)
  if not color then return "" end
  capability = term_capability(capability)
  local prefix = background and 48 or 38
  if color.kind == "palette" then
    if color.index < 8 then return "\27[" .. (background and 40 or 30) + color.index .. "m" end
    return "\27[" .. (background and 100 or 90) + color.index - 8 .. "m"
  end
  if color.kind == "index" then
    if capability == "ansi256" or capability == "truecolor" then return "\27[" .. prefix .. ";5;" .. color.index .. "m" end
    local r = xterm256_rgb(color.index)
    return M.sgr({ kind = "palette", index = nearest16({ r = r[1], g = r[2], b = r[3] }) }, background, capability)
  end
  if capability == "truecolor" then return "\27[" .. prefix .. ";2;" .. color.r .. ";" .. color.g .. ";" .. color.b .. "m" end
  if capability == "ansi256" then return "\27[" .. prefix .. ";5;" .. nearest256(color) .. "m" end
  return M.sgr({ kind = "palette", index = nearest16(color) }, background, capability)
end

function M.from_sgr(params, currentFg, currentBg)
  local values = {}
  for n in tostring(params):gmatch("%d+") do values[#values + 1] = tonumber(n) end
  local fg, bg = currentFg, currentBg
  local style = {}
  local i = 1
  while i <= #values do
    local n = values[i]
    if n == 0 then fg, bg, style = nil, nil, {}
    elseif n == 1 then style.bold = true elseif n == 2 then style.dim = true elseif n == 3 then style.italic = true
    elseif n == 4 then style.underline = true elseif n == 7 then style.inverse = true elseif n == 9 then style.strikethrough = true
    elseif n == 22 then style.bold, style.dim = false, false elseif n == 23 then style.italic = false elseif n == 24 then style.underline = false
    elseif n == 27 then style.inverse = false elseif n == 29 then style.strikethrough = false
    elseif n >= 30 and n <= 37 then fg = { kind = "palette", index = n - 30 } elseif n >= 90 and n <= 97 then fg = { kind = "palette", index = n - 90 + 8 }
    elseif n == 39 then fg = nil elseif n >= 40 and n <= 47 then bg = { kind = "palette", index = n - 40 } elseif n >= 100 and n <= 107 then bg = { kind = "palette", index = n - 100 + 8 } elseif n == 49 then bg = nil
    elseif (n == 38 or n == 48) and values[i + 1] == 5 and values[i + 2] then
      if n == 38 then fg = { kind = "index", index = clamp(values[i + 2], 0, 255) } else bg = { kind = "index", index = clamp(values[i + 2], 0, 255) } end
      i = i + 2
    elseif (n == 38 or n == 48) and values[i + 1] == 2 and values[i + 4] then
      local color = { kind = "rgb", r = clamp(values[i + 2], 0, 255), g = clamp(values[i + 3], 0, 255), b = clamp(values[i + 4], 0, 255) }
      if n == 38 then fg = color else bg = color end
      i = i + 4
    end
    i = i + 1
  end
  return fg, bg, style
end

M.palette = PALETTE
return M
