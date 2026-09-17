--[[
  hydronium_ink.text_metrics -- UTF-8 decoding, per-codepoint terminal
  display width, and practical grapheme-cluster segmentation.

  Why this exists: host/terminal.lua used to treat `#text` (byte count)
  as both "number of terminal cells" and "number of paint iterations",
  writing one BYTE per cell via `text:sub(j, j)`. That is only correct
  for 7-bit ASCII. Any multi-byte UTF-8 character (accented Latin, CJK,
  emoji, ...) got split across multiple cells, each holding one raw
  continuation byte -- not just mis-measured, but genuinely corrupted
  on screen. This module is what host/terminal.lua now goes through
  instead, everywhere it used to count/iterate `#text`.

  SCOPE: this is a practical, hand-maintained approximation of the real
  Unicode UAX #29 grapheme-segmentation algorithm and the real
  East-Asian-Width property table, not a generated-from-UCD one (there
  is no Unicode-data-generation tooling in this repo, and no network
  access from this environment to pull the authoritative files). It
  covers the ranges a terminal UI actually hits in practice: combining
  diacritics on Latin/Cyrillic/Hebrew/Arabic/Devanagari text, CJK +
  Hangul + fullwidth forms, common emoji blocks (including ZWJ
  sequences and skin-tone modifiers), and regional-indicator flag
  pairs. It will misjudge width for scripts/blocks outside these
  ranges (treating them as narrow, single-codepoint clusters) --
  narrower coverage than a full ICU-backed implementation, but strictly
  better than the byte-per-cell model it replaces, which had none.
--]]

local M = {}

--- Decodes the UTF-8 codepoint starting at byte index `i` (1-based) of
--- `s`. Never errors: a malformed or truncated sequence (a stray
--- continuation byte as a lead byte, a lead byte with no valid
--- continuation bytes following it, etc.) decodes as a single raw byte
--- standing for itself, so arbitrary/non-UTF-8 byte strings still make
--- forward progress one byte at a time instead of this module raising.
--- @param s string
--- @param i integer
--- @return integer|nil codepoint  nil only when `i` is past the end of `s`.
--- @return integer nextIndex
function M.nextCodepoint(s, i)
  local b1 = s:byte(i)
  if not b1 then return nil, i end

  if b1 < 0x80 then
    return b1, i + 1
  elseif b1 >= 0xC2 and b1 <= 0xDF then
    local b2 = s:byte(i + 1)
    if b2 and b2 >= 0x80 and b2 <= 0xBF then
      return (b1 % 0x20) * 0x40 + (b2 % 0x40), i + 2
    end
  elseif b1 >= 0xE0 and b1 <= 0xEF then
    local b2, b3 = s:byte(i + 1), s:byte(i + 2)
    if b2 and b3 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
      return (b1 % 0x10) * 0x1000 + (b2 % 0x40) * 0x40 + (b3 % 0x40), i + 3
    end
  elseif b1 >= 0xF0 and b1 <= 0xF4 then
    local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
    if b2 and b3 and b4 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
      return (b1 % 0x08) * 0x40000 + (b2 % 0x40) * 0x1000 + (b3 % 0x40) * 0x40 + (b4 % 0x40), i + 4
    end
  end

  return b1, i + 1
end

-- Zero-width codepoints: combining marks (Mn/Me-ish) for the scripts a
-- terminal UI is likely to actually render, plus format characters
-- (ZWSP/ZWNJ/ZWJ, directional marks, variation selectors) and emoji
-- skin-tone modifiers (which visually recolor the preceding base emoji
-- rather than occupying their own cell).
local ZERO_WIDTH_RANGES = {
  { 0x0300, 0x036F }, -- Combining Diacritical Marks
  { 0x0483, 0x0489 }, -- Cyrillic combining
  { 0x0591, 0x05BD }, { 0x05BF, 0x05BF }, { 0x05C1, 0x05C2 }, { 0x05C4, 0x05C5 }, { 0x05C7, 0x05C7 }, -- Hebrew points
  { 0x0610, 0x061A }, { 0x064B, 0x065F }, { 0x0670, 0x0670 }, -- Arabic marks
  { 0x06D6, 0x06DC }, { 0x06DF, 0x06E4 }, { 0x06E7, 0x06E8 }, { 0x06EA, 0x06ED },
  { 0x0711, 0x0711 }, { 0x0730, 0x074A },
  { 0x07A6, 0x07B0 },
  { 0x0816, 0x0819 }, { 0x081B, 0x0823 }, { 0x0825, 0x0827 }, { 0x0829, 0x082D },
  { 0x0900, 0x0902 }, { 0x093A, 0x093A }, { 0x093C, 0x093C }, { 0x0941, 0x0948 }, { 0x094D, 0x094D }, { 0x0951, 0x0957 }, { 0x0962, 0x0963 }, -- Devanagari
  { 0x200B, 0x200F }, -- ZWSP, ZWNJ, ZWJ, LRM, RLM
  { 0x202A, 0x202E }, -- directional formatting
  { 0x2060, 0x2064 },
  { 0x20D0, 0x20FF }, -- Combining Diacritical Marks for Symbols
  { 0x1AB0, 0x1AFF }, -- Combining Diacritical Marks Extended
  { 0x1DC0, 0x1DFF }, -- Combining Diacritical Marks Supplement
  { 0xFE00, 0xFE0F }, -- Variation Selectors
  { 0xFE20, 0xFE2F }, -- Combining Half Marks
  { 0x1F3FB, 0x1F3FF }, -- Emoji skin tone modifiers
}

-- 2-cell-wide codepoints: CJK + Hangul + fullwidth forms + the common
-- emoji blocks. Based on the well-known East-Asian-Width "Wide"/
-- "Fullwidth" ranges used by most terminal wcwidth() implementations.
local WIDE_RANGES = {
  { 0x1100, 0x115F }, -- Hangul Jamo
  { 0x2329, 0x232A },
  { 0x2E80, 0x303E }, -- CJK Radicals .. CJK Symbols/Punctuation
  { 0x3041, 0x33FF }, -- Hiragana .. CJK Compatibility
  { 0x3400, 0x4DBF }, -- CJK Extension A
  { 0x4E00, 0x9FFF }, -- CJK Unified Ideographs
  { 0xA000, 0xA4CF }, -- Yi Syllables/Radicals
  { 0xAC00, 0xD7A3 }, -- Hangul Syllables
  { 0xF900, 0xFAFF }, -- CJK Compatibility Ideographs
  { 0xFE30, 0xFE4F }, -- CJK Compatibility Forms
  { 0xFF00, 0xFF60 }, -- Fullwidth Forms
  { 0xFFE0, 0xFFE6 },
  { 0x16FE0, 0x16FE4 },
  { 0x17000, 0x18AFF }, -- Tangut
  { 0x1B000, 0x1B2FF }, -- Kana Supplement/Extended
  { 0x1F200, 0x1F2FF }, -- Enclosed Ideographic Supplement
  { 0x1F300, 0x1F64F }, -- Misc Symbols and Pictographs, Emoticons
  { 0x1F680, 0x1F6FF }, -- Transport and Map Symbols
  { 0x1F900, 0x1F9FF }, -- Supplemental Symbols and Pictographs
  { 0x1FA70, 0x1FAFF }, -- Symbols and Pictographs Extended-A
  { 0x20000, 0x2FFFD }, -- CJK Extension B..F, Compatibility Ideographs Supplement
  { 0x30000, 0x3FFFD }, -- CJK Extension G+
}

local ZWJ = 0x200D
local REGIONAL_INDICATOR_LO, REGIONAL_INDICATOR_HI = 0x1F1E6, 0x1F1FF

local function isControl(cp)
  return (cp >= 0x01 and cp <= 0x1F) or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F)
end

local function inRanges(cp, ranges)
  -- Linear scan: these tables are small (dozens of entries), and this
  -- runs per-codepoint during paint -- a binary search would only
  -- matter if these grew into the thousands of entries a real
  -- generated UCD table would have.
  for _, r in ipairs(ranges) do
    if cp >= r[1] and cp <= r[2] then return true end
  end
  return false
end

--- Display width (terminal columns) of a single codepoint: 0 for
--- combining/format characters and C0/C1 controls, 2 for wide/fullwidth
--- codepoints, 1 for everything else.
--- @param cp integer
--- @return 0|1|2
function M.codepointWidth(cp)
  if cp == 0 or isControl(cp) then return 0 end
  if inRanges(cp, ZERO_WIDTH_RANGES) then return 0 end
  if inRanges(cp, WIDE_RANGES) then return 2 end
  return 1
end

--- @class hydronium_ink.Grapheme
--- @field text string The raw UTF-8 bytes of this cluster.
--- @field width 0|1|2 Its total terminal display width.

--- Segments `s` into grapheme clusters for terminal display: each
--- cluster is one "base" codepoint plus any trailing zero-width
--- combining/modifier codepoints, with Zero-Width-Joiner sequences
--- (`base ZWJ base ZWJ base ...`) and adjacent regional-indicator pairs
--- (flag emoji) also merged into a single cluster.
--- @param s string
--- @return hydronium_ink.Grapheme[]
function M.clusters(s)
  local result = {}
  local len = #s
  local i = 1
  local clusterStart = nil
  local clusterWidth = 0
  local lastBaseCp = nil
  local expectJoinContinuation = false

  local function flush(endIdx)
    if clusterStart then
      result[#result + 1] = { text = s:sub(clusterStart, endIdx - 1), width = clusterWidth }
    end
    clusterStart = nil
    clusterWidth = 0
    lastBaseCp = nil
  end

  while i <= len do
    local cp, nextI = M.nextCodepoint(s, i)
    if not cp then break end
    local w = M.codepointWidth(cp)

    if isControl(cp) then
      -- Dropped entirely, never attached to a neighboring cluster: unlike
      -- a real combining mark, a control byte (e.g. a stray tab or CR
      -- inside Text content) has no glyph of its own to combine with one,
      -- and letting it ride along inside a cell's `.text` would leak a
      -- raw control byte into the ANSI output stream outside this
      -- module's own cursor-tracking model.
      flush(i)
    elseif clusterStart == nil then
      -- Starting a brand new cluster (a stray combining mark with no
      -- base to attach to still gets its own zero-width cluster --
      -- there is nothing sensible to merge it into).
      clusterStart = i
      clusterWidth = w
      lastBaseCp = cp
      expectJoinContinuation = (cp == ZWJ)
    elseif w == 0 and cp ~= ZWJ then
      -- Combining mark/modifier: extends the current cluster without
      -- adding width.
      expectJoinContinuation = false
    elseif cp == ZWJ then
      -- ZWJ glues whatever comes next into this same cluster too
      -- (multi-codepoint emoji like a family or a profession-plus-
      -- gender sequence).
      expectJoinContinuation = true
    elseif expectJoinContinuation then
      clusterWidth = math.max(clusterWidth, w)
      lastBaseCp = cp
      expectJoinContinuation = false
    elseif lastBaseCp and lastBaseCp >= REGIONAL_INDICATOR_LO and lastBaseCp <= REGIONAL_INDICATOR_HI
        and cp >= REGIONAL_INDICATOR_LO and cp <= REGIONAL_INDICATOR_HI then
      -- Second half of a flag emoji (two regional indicators).
      clusterWidth = 2
      lastBaseCp = nil -- a flag is exactly 2 indicators, never 3+
    else
      flush(i)
      clusterStart = i
      clusterWidth = w
      lastBaseCp = cp
    end

    i = nextI
  end
  flush(i)

  return result
end

--- Total terminal display width of `s` (sum of its clusters' widths).
--- @param s string
--- @return integer
function M.displayWidth(s)
  local total = 0
  for _, g in ipairs(M.clusters(s)) do
    total = total + g.width
  end
  return total
end

return M
