--[[
  hydronium_ink.keys -- parses raw stdin bytes (as delivered by
  tty_ffi.readAvailable, non-blocking, possibly split across multiple
  reads) into Ink-shaped `{input, key}` events, matching the exact `key`
  field vocabulary real Ink's README documents for `useInput`:
  leftArrow/rightArrow/upArrow/downArrow, return, escape, ctrl, tab,
  backspace, delete, pageUp/pageDown, home/end, plus the real modifier
  set: shift/alt/ctrl/super.

  MODIFIERS come from two sources, both parsed here:
    - xterm's parameterised forms, `ESC [ 1 ; <mod> <letter>` for arrows
      and home/end and `ESC [ <n> ; <mod> ~` for the tilde keys.
    - the Kitty keyboard protocol's `ESC [ <codepoint> ; <mod> u`, which
      render.lua opts into by pushing flag 1 ("disambiguate escape
      codes") at raw-mode setup and popping it on exit.
  The wire encoding is 1 + a bitmask: 1 shift, 2 alt, 4 ctrl, 8 super.
  Flag 1 deliberately does NOT ask the terminal to report every key as an
  escape code, so ordinary typing still arrives as plain bytes; only the
  otherwise-ambiguous keys change shape.

  An undetected modifier is ABSENT, never `false` -- a terminal that does
  not implement the protocol simply sends the old unparameterised
  sequences, and this module says nothing rather than claiming a
  modifier was known not to be held. `hyper`/`capsLock`/`numLock`/
  `eventType` from real Ink's key object are still not populated.

  Also recognizes bracketed-paste markers (`ESC[200~...ESC[201~`, DECSET
  2004 -- render.lua enables/disables the terminal mode itself, this
  module only parses the resulting byte stream) and produces a distinct
  `hydronium_ink.PasteEvent` (`{type="paste", text=...}`) instead of
  ordinary key events for the bytes in between, dispatched separately via
  `usePaste` (see hooks.lua) rather than through `useInput`.

  A real, stateful parser, not a lookup table alone: a multi-byte escape
  sequence (`ESC [ A` for an up-arrow, etc.) can arrive split across
  separate non-blocking reads under real terminal/pty latency, and a
  lone Escape keypress produces exactly one byte (0x1B) with nothing
  following it -- which is byte-for-byte indistinguishable from the
  START of a real multi-byte sequence until either more bytes arrive or
  a short timeout proves no more are coming. `feed()` buffers and
  extracts every event it can find immediately; `flushTimedOut()` (call
  once per event-loop iteration -- see render.lua) finalizes a
  lone-pending ESC once enough real time has passed with nothing more
  arriving.
--]]

local M = {}

--- @class hydronium_ink.Key
--- @field leftArrow? boolean
--- @field rightArrow? boolean
--- @field upArrow? boolean
--- @field downArrow? boolean
--- @field return? boolean
--- @field escape? boolean
--- @field ctrl? boolean
--- @field tab? boolean
--- @field backspace? boolean
--- @field delete? boolean
--- @field pageUp? boolean
--- @field pageDown? boolean
--- @field home? boolean
--- @field end? boolean
--- @field shift? boolean Set from a modifier parameter on a parameterised
---   CSI or Kitty CSI-u sequence, and for Shift+Tab, which xterm-family
---   terminals send as its own distinct sequence (`ESC [ Z`) rather than a
---   modifier bit on plain Tab. Absent, never `false`, when the terminal
---   sent no modifier information at all.
--- @field alt? boolean See `shift`.
--- @field super? boolean The Command key on macOS. Reachable only through
---   the Kitty keyboard protocol: the OS and terminal consume Command
---   before it can become stdin bytes in any other encoding.

--- @class hydronium_ink.KeyEvent
--- @field input string Empty string for a pure special key (matches real Ink).
--- @field key hydronium_ink.Key

--- @class hydronium_ink.PasteEvent
--- @field type "paste"
--- @field text string The pasted text, verbatim -- newlines and any other bytes the terminal delivered between the bracketed-paste markers are passed through unparsed (see PASTE_START/PASTE_END below), matching real Ink's own documented usePaste behavior.

-- ESC-alone disambiguation window: how long to wait (from the moment a
-- lone 0x1B is buffered) before finalizing it as a real standalone
-- Escape keypress rather than the still-arriving start of a longer
-- sequence. 50ms is generously long relative to real local-terminal/pty
-- latency (effectively instantaneous) but short enough that a real
-- Escape keypress doesn't feel laggy to a human.
local ESCAPE_TIMEOUT_MS = 50

-- ESC [ <letter> -> named key (the common xterm CSI form).
local CSI_LETTER_KEYS = {
  A = "upArrow",
  B = "downArrow",
  C = "rightArrow",
  D = "leftArrow",
  H = "home",
  F = "end_",
}

-- Bracketed-paste markers (DECSET 2004 -- render.lua enables this on the
-- real terminal at raw-mode setup and disables it on exit): a paste
-- delivers as literal, unparsed bytes wrapped between these two exact
-- byte strings, specifically so a parser can tell "the user actually
-- typed these characters very fast" apart from "this text arrived via
-- paste" -- and, just as importantly here, so pasted content that
-- happens to itself contain CSI/escape-looking bytes doesn't get
-- misinterpreted as real key sequences.
local PASTE_START = "\27[200~"
local PASTE_END = "\27[201~"

-- ESC [ <digits> ~ -> named key (the xterm "tilde" CSI form).
local CSI_TILDE_KEYS = {
  ["1"] = "home",
  ["2"] = nil, -- Insert -- not in real Ink's documented key vocabulary, not surfaced
  ["3"] = "delete",
  ["4"] = "end_",
  ["5"] = "pageUp",
  ["6"] = "pageDown",
  ["7"] = "home",
  ["8"] = "end_",
}

--- @param name string
--- @return hydronium_ink.KeyEvent
local function specialKey(name)
  local key = {}
  -- "end" is a Lua keyword -- stored/looked-up internally as "end_" and
  -- translated to the real field name only in the event actually handed
  -- to user code, so this module's own internal tables can use plain
  -- string keys without needing `["end"]` everywhere.
  key[name == "end_" and "end" or name] = true
  return { input = "", key = key }
end

--- @param ch string A single already-decoded UTF-8 character (1-4 bytes).
--- @return hydronium_ink.KeyEvent
local function plainChar(ch)
  return { input = ch, key = {} }
end

--- @param letter string Lowercase a-z.
--- @return hydronium_ink.KeyEvent
local function ctrlLetter(letter)
  return { input = letter, key = { ctrl = true } }
end

--- @param byte0 integer
--- @return integer length 1-4, the real UTF-8 sequence length for a
---   leading byte, matching the same technique
---   tests/host/terminal_spec.lua's own ANSI interpreter uses to avoid
---   splitting a multi-byte character.
local function utf8SeqLen(byte0)
  if byte0 < 0x80 then return 1 end
  if byte0 >= 0xF0 then return 4 end
  if byte0 >= 0xE0 then return 3 end
  if byte0 >= 0xC0 then return 2 end
  return 1 -- a stray continuation byte on its own; treat as one byte rather than misreading further
end

-- Kitty CSI-u codepoints that name a key rather than producing text.
local CSI_U_NAMED = {
  [9] = "tab",
  [13] = "return",
  [27] = "escape",
  [127] = "backspace",
}

--- Encodes one unicode codepoint as UTF-8. Lua 5.1/LuaJIT has no
--- `utf8.char`, and Kitty reports keys by codepoint, so CSI-u needs this to
--- turn a reported key back into the character it stands for.
--- @param cp integer
--- @return string
local function utf8Char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

--- The first two parameters of a CSI parameter string.
---
--- Kitty may attach ':'-separated SUB-parameters to any parameter (an event
--- type on the modifier, a shifted codepoint on the key). Only the primary
--- value of each is used here; the sub-parameters are parsed off rather than
--- being allowed to corrupt a tonumber().
--- @param params string
--- @return string|nil first, string|nil second
local function splitParams(params)
  local function primary(p)
    if not p or p == "" then return nil end
    local head = p:match("^([^:]*)")
    if head == "" then return nil end
    return head
  end
  local first, rest = params:match("^([^;]*);?(.*)$")
  return primary(first), primary(rest and rest:match("^([^;]*)"))
end

--- Decodes an xterm/Kitty modifier parameter into key flags.
---
--- The wire value is 1 + a bitmask: 1 shift, 2 alt, 4 ctrl, 8 super. A value
--- of 1 (or absent) means no modifiers, so it returns nil rather than a table
--- of falses -- this module's norm is that an undetected modifier is ABSENT,
--- never `false`, so callers cannot mistake "not held" for "known not held".
--- @param param string|nil
--- @return table|nil
local function decodeModifiers(param)
  local n = tonumber(param)
  if not n or n < 2 then
    return nil
  end
  local bits = n - 1
  local function has(mask)
    return math.floor(bits / mask) % 2 == 1 or nil
  end
  return { shift = has(1), alt = has(2), ctrl = has(4), super = has(8) }
end

--- @param event hydronium_ink.KeyEvent
--- @param mods table|nil
--- @return hydronium_ink.KeyEvent
local function applyModifiers(event, mods)
  if mods then
    for name, value in pairs(mods) do
      event.key[name] = value
    end
  end
  return event
end

--- Builds the event for a Kitty `ESC [ <codepoint> ; <mod> u` sequence.
--- @param codepointParam string|nil
--- @param mods table|nil
--- @return hydronium_ink.KeyEvent|nil
local function csiUEvent(codepointParam, mods)
  local cp = tonumber(codepointParam)
  if not cp or cp < 0 then
    return nil
  end
  local named = CSI_U_NAMED[cp]
  if named then
    return applyModifiers(specialKey(named), mods)
  end
  return applyModifiers(plainChar(utf8Char(cp)), mods)
end

--- @class hydronium_ink.KeyParser
local Parser = {}
Parser.__index = Parser

function M.newParser()
  return setmetatable({ buffer = "", escPendingSinceMs = nil, pasteMode = false }, Parser)
end

--- Tries to consume exactly one event from the front of `self.buffer`.
--- @return hydronium_ink.KeyEvent|hydronium_ink.PasteEvent|nil event
--- @return boolean needMoreData True if the buffer holds an incomplete
---   sequence that might still complete once more bytes arrive (the
---   caller must not discard the buffer in this case).
function Parser:tryConsumeOne()
  local buf = self.buffer
  if #buf == 0 then
    return nil, false
  end

  if self.pasteMode then
    -- Not a byte-by-byte scan like the rest of this parser -- correct
    -- here because paste content is explicitly NOT meant to be
    -- interpreted a byte at a time (see PASTE_START's own doc comment).
    -- Everything up to PASTE_END is the pasted text, verbatim; if
    -- PASTE_END hasn't arrived yet (a large paste split across several
    -- non-blocking reads), wait for more rather than guessing where it
    -- ends. NOT bounded -- an unterminated paste (e.g. bracketed-paste
    -- support toggled off mid-stream) would grow this buffer forever;
    -- not guarded against, a real but narrow edge case.
    local termIdx = buf:find(PASTE_END, 1, true)
    if not termIdx then
      return nil, true
    end
    local text = buf:sub(1, termIdx - 1)
    self.buffer = buf:sub(termIdx + #PASTE_END)
    self.pasteMode = false
    return { type = "paste", text = text }, false
  end

  if buf:sub(1, #PASTE_START) == PASTE_START then
    self.buffer = buf:sub(#PASTE_START + 1)
    self.pasteMode = true
    return nil, false
  end
  if #buf < #PASTE_START and PASTE_START:sub(1, #buf) == buf then
    -- The start marker itself arrived split across reads -- wait for
    -- the rest rather than misreading a prefix of it as ordinary bytes.
    return nil, true
  end

  local b0 = buf:byte(1)

  if b0 == 0x1B then
    if #buf == 1 then
      return nil, true -- lone ESC so far -- see flushTimedOut()
    end
    if buf:byte(2) == 0x5B then -- '['
      if #buf < 3 then
        return nil, true
      end
      local letterByte = buf:byte(3)
      local letter = string.char(letterByte)

      if letter == "Z" then
        -- ESC [ Z -- Shift+Tab, the one modifier combination xterm-family
        -- terminals encode as its own distinct CSI sequence rather than
        -- a bit on plain Tab. See the shift field's own doc comment above.
        self.buffer = buf:sub(4)
        local event = specialKey("tab")
        event.key.shift = true
        return event, false
      end

      if CSI_LETTER_KEYS[letter] then
        self.buffer = buf:sub(4)
        return specialKey(CSI_LETTER_KEYS[letter]), false
      end

      if letter:match("%d") then
        -- A parameterised CSI sequence: ESC [ <params> <final>, where
        -- params are digits separated by ';' (Kitty may add ':'-separated
        -- sub-parameters, which are parsed off and ignored) and <final> is
        -- '~' (xterm tilde keys), 'u' (Kitty CSI-u), or a letter (xterm
        -- letter keys carrying a modifier parameter, e.g. ESC [ 1;2C for
        -- Shift+Right).
        --
        -- This branch used to handle only `ESC [ <digits> ~`. Generalising
        -- it is what makes modifiers visible at all: without a modifier
        -- parameter there is nothing to read Shift or Super off, which is
        -- why `shift` was previously documented as detectable for Shift+Tab
        -- and nothing else.
        local params, afterParams = buf:match("^\27%[([%d;:]*)()", 1)
        if not params or afterParams > #buf then
          return nil, true
        end
        local finalByte = buf:byte(afterParams)
        local finalChar = string.char(finalByte)

        local isTilde = finalByte == 0x7E
        local isCsiU = finalChar == "u"
        local isLetter = CSI_LETTER_KEYS[finalChar] ~= nil

        if not (isTilde or isCsiU or isLetter) then
          -- Not a sequence this module understands. Consume just the ESC so
          -- the rest of the buffer is reprocessed as plain bytes rather
          -- than silently dropping real subsequent input.
          self.buffer = buf:sub(2)
          return specialKey("escape"), false
        end

        self.buffer = buf:sub(afterParams + 1)
        local first, second = splitParams(params)
        local mods = decodeModifiers(second)

        if isLetter then
          -- ESC [ 1 ; <mod> <letter>. The first parameter is a placeholder
          -- (always 1 here); the modifier lives in the second.
          local event = specialKey(CSI_LETTER_KEYS[finalChar])
          applyModifiers(event, mods)
          return event, false
        end

        if isTilde then
          local name = CSI_TILDE_KEYS[first]
          if name then
            local event = specialKey(name)
            applyModifiers(event, mods)
            return event, false
          end
          return nil, false -- recognized-but-unmapped (e.g. Insert)
        end

        -- Kitty CSI-u: ESC [ <codepoint> ; <mod> u. The first parameter is
        -- the key's unicode codepoint, so a plain letter arrives here too
        -- once progressive enhancement is on -- which is the whole point:
        -- Ctrl+A and Shift+A stop being indistinguishable from 0x01 and 'A'.
        return csiUEvent(first, mods), false
      end

      -- Unrecognized CSI sequence: consume ESC '[' and reprocess the
      -- rest, rather than getting stuck forever on bytes this parser
      -- doesn't understand.
      self.buffer = buf:sub(3)
      return specialKey("escape"), false
    end

    -- ESC followed by something other than '[' (e.g. an Alt+key Meta
    -- sequence in some terminals' encodings) -- not specifically
    -- decoded by this module (real Ink's `meta` key field is one of the
    -- fields this module doesn't attempt, see the module doc comment);
    -- consume just the ESC as a standalone Escape and let the following
    -- byte(s) be reprocessed normally.
    self.buffer = buf:sub(2)
    return specialKey("escape"), false
  end

  if b0 == 0x0D or b0 == 0x0A then
    self.buffer = buf:sub(2)
    return specialKey("return"), false
  end

  if b0 == 0x7F or b0 == 0x08 then
    self.buffer = buf:sub(2)
    return specialKey("backspace"), false
  end

  if b0 == 0x09 then
    self.buffer = buf:sub(2)
    return specialKey("tab"), false
  end

  if b0 >= 0x01 and b0 <= 0x1A then
    -- Ctrl+<letter> -- byte 0x01 is Ctrl+A ('a' is 0x61, 0x61-0x60=0x01).
    self.buffer = buf:sub(2)
    return ctrlLetter(string.char(b0 + 0x60)), false
  end

  -- Ordinary character, ASCII or a real multi-byte UTF-8 sequence.
  local len = utf8SeqLen(b0)
  if #buf < len then
    return nil, true
  end
  local ch = buf:sub(1, len)
  self.buffer = buf:sub(len + 1)
  return plainChar(ch), false
end

--- Feeds newly-read bytes in and returns every complete event they
--- produced (possibly together with bytes already buffered from a
--- previous, incomplete read).
--- @param bytes string
--- @return hydronium_ink.KeyEvent[]
function Parser:feed(bytes)
  self.buffer = self.buffer .. bytes
  self.escPendingSinceMs = nil

  local events = {}
  while true do
    local event, needMoreData = self:tryConsumeOne()
    if event then
      table.insert(events, event)
    elseif needMoreData then
      if self.buffer == "\27" then
        self.escPendingSinceMs = require("hydronium_ink.clock").nowMs()
      end
      break
    elseif #self.buffer == 0 then
      break
    end
    -- else: a byte sequence was silently consumed with no event (e.g. an
    -- unmapped CSI tilde code) -- keep looping, more may follow.
  end
  return events
end

--- Call once per event-loop iteration regardless of whether new bytes
--- arrived. Finalizes a lone-pending ESC into a real standalone Escape
--- event once `ESCAPE_TIMEOUT_MS` has passed with nothing further
--- arriving -- see this module's own doc comment for why this
--- disambiguation is necessary at all.
--- @param nowMs? number Defaults to `hydronium_ink.clock.nowMs()` (a real
---   wall-clock reading -- NOT `os.clock()`, which is CPU time and barely
---   advances while render.lua's loop sits blocked in `select()`; see
---   clock.lua's own doc comment for the real measurement that caught
---   this). A parameter purely so tests can pass a fixed time instead of
---   racing a real clock.
--- @return hydronium_ink.KeyEvent|nil
function Parser:flushTimedOut(nowMs)
  if self.buffer ~= "\27" or not self.escPendingSinceMs then
    return nil
  end
  nowMs = nowMs or require("hydronium_ink.clock").nowMs()
  if nowMs - self.escPendingSinceMs < ESCAPE_TIMEOUT_MS then
    return nil
  end
  self.buffer = ""
  self.escPendingSinceMs = nil
  return specialKey("escape")
end

M.Parser = Parser

return M
