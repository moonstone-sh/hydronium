--[[
  hydronium_cli.ui.search_field -- editing state for the fullscreen view's
  filter bar.

  Deliberately PURE: `handle_key` takes a state and an event and returns a new
  state plus an optional intent. No rendering, no signals, no terminal. That
  is what makes caret arithmetic, selection and word motion testable without a
  pty -- the part of a text input that actually breaks is the arithmetic, and
  it is the part a screenshot test would never catch.

  KEY BINDINGS. Two families, because one of them only exists on terminals
  that speak the Kitty keyboard protocol (see hydronium_ink.keys):

    Always available (plain xterm encodings)
      Ctrl+A / Ctrl+E     start / end of line
      Ctrl+W              delete the word before the caret
      Ctrl+U / Ctrl+K     kill to start / to end
      Left / Right        move the caret
      Home / End          start / end
      Backspace / Delete  delete around the caret

    Requires modifier reporting (Kitty protocol)
      Shift+Left/Right    extend the selection
      Alt+Left/Right      move by word
      Super+Left/Right    start / end of line (Command on macOS)
      Super+C / Super+V   copy / paste

  Super is Command on macOS and is otherwise unreachable: the OS and terminal
  consume it before it can become stdin bytes. Every Super binding therefore
  has a plain-terminal equivalent above it, so the field stays fully usable
  where the protocol is unsupported.

  Paste arrives as a PasteEvent from bracketed paste, not as a key, and works
  everywhere regardless of the protocol.
--]]

local M = {}

--- @class hydronium_cli.SearchFieldState
--- @field text string
--- @field cursor integer 0-based caret position: 0 is before the first byte.
--- @field anchor integer|nil Selection anchor, or nil when nothing is selected.

--- @return hydronium_cli.SearchFieldState
function M.new_state(text)
  return { text = text or "", cursor = #(text or ""), anchor = nil }
end

--- The selected range as inclusive-exclusive byte offsets, or nil.
--- @param state hydronium_cli.SearchFieldState
--- @return integer|nil from, integer|nil to
function M.selection(state)
  if not state.anchor or state.anchor == state.cursor then return nil end
  local a, b = state.anchor, state.cursor
  if a > b then a, b = b, a end
  return a, b
end

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

--- Start of the word at or before `pos`.
local function wordLeft(text, pos)
  local i = pos
  while i > 0 and text:sub(i, i):match("%s") do i = i - 1 end
  while i > 0 and not text:sub(i, i):match("%s") do i = i - 1 end
  return i
end

--- End of the word at or after `pos`.
local function wordRight(text, pos)
  local n = #text
  local i = pos
  while i < n and text:sub(i + 1, i + 1):match("%s") do i = i + 1 end
  while i < n and not text:sub(i + 1, i + 1):match("%s") do i = i + 1 end
  return i
end

--- Replaces the current selection (if any) with `insert`.
--- @return hydronium_cli.SearchFieldState
local function replaceSelection(state, insert)
  local from, to = M.selection(state)
  if not from then
    local text = state.text:sub(1, state.cursor) .. insert .. state.text:sub(state.cursor + 1)
    return { text = text, cursor = state.cursor + #insert, anchor = nil }
  end
  local text = state.text:sub(1, from) .. insert .. state.text:sub(to + 1)
  return { text = text, cursor = from + #insert, anchor = nil }
end

--- Moves the caret, extending or collapsing the selection.
---
--- `extend` is what Shift does: keep the anchor where it was so the selection
--- grows. Without it the anchor is dropped, which is why pressing an arrow
--- after selecting deselects rather than leaving a stale highlight.
local function moveTo(state, pos, extend)
  pos = clamp(pos, 0, #state.text)
  local anchor = nil
  if extend then
    anchor = state.anchor or state.cursor
    if anchor == pos then anchor = nil end
  end
  return { text = state.text, cursor = pos, anchor = anchor }
end

--- Applies one key or paste event.
---
--- @param state hydronium_cli.SearchFieldState
--- @param event table A hydronium_ink KeyEvent or PasteEvent.
--- @return hydronium_cli.SearchFieldState state
--- @return table|nil intent `{ type = "copy", text = ... }` when the binding
---   asks for something this module cannot do itself (the clipboard is the
---   renderer's business, via OSC 52).
function M.handle_key(state, event)
  if not event then return state, nil end

  -- Bracketed paste: insert verbatim, minus newlines, which would otherwise
  -- turn a one-line filter into something unrenderable.
  if event.type == "paste" then
    return replaceSelection(state, (event.text or ""):gsub("[\r\n]+", " ")), nil
  end

  local key = event.key or {}
  local input = event.input or ""
  local extend = key.shift == true
  local byWord = key.alt == true
  local toEdge = key.super == true

  if key.leftArrow then
    if toEdge then return moveTo(state, 0, extend) end
    if byWord then return moveTo(state, wordLeft(state.text, state.cursor), extend) end
    -- A plain Left with a selection collapses to its start rather than
    -- stepping back from the caret, which is what every text field does.
    local from = M.selection(state)
    if from and not extend then return moveTo(state, from, false) end
    return moveTo(state, state.cursor - 1, extend)
  end

  if key.rightArrow then
    if toEdge then return moveTo(state, #state.text, extend) end
    if byWord then return moveTo(state, wordRight(state.text, state.cursor), extend) end
    local _, to = M.selection(state)
    if to and not extend then return moveTo(state, to, false) end
    return moveTo(state, state.cursor + 1, extend)
  end

  if key.home then return moveTo(state, 0, extend) end
  if key["end"] then return moveTo(state, #state.text, extend) end

  if key.backspace then
    if M.selection(state) then return replaceSelection(state, "") end
    if state.cursor == 0 then return state, nil end
    return {
      text = state.text:sub(1, state.cursor - 1) .. state.text:sub(state.cursor + 1),
      cursor = state.cursor - 1,
      anchor = nil,
    }, nil
  end

  if key.delete then
    if M.selection(state) then return replaceSelection(state, "") end
    if state.cursor >= #state.text then return state, nil end
    return {
      text = state.text:sub(1, state.cursor) .. state.text:sub(state.cursor + 2),
      cursor = state.cursor,
      anchor = nil,
    }, nil
  end

  if key.ctrl then
    if input == "a" then return moveTo(state, 0, false) end
    if input == "e" then return moveTo(state, #state.text, false) end
    if input == "u" then
      return { text = state.text:sub(state.cursor + 1), cursor = 0, anchor = nil }, nil
    end
    if input == "k" then
      return { text = state.text:sub(1, state.cursor), cursor = state.cursor, anchor = nil }, nil
    end
    if input == "w" then
      local start = wordLeft(state.text, state.cursor)
      return {
        text = state.text:sub(1, start) .. state.text:sub(state.cursor + 1),
        cursor = start,
        anchor = nil,
      }, nil
    end
    if input == "c" then
      local from, to = M.selection(state)
      if from then return state, { type = "copy", text = state.text:sub(from + 1, to) } end
      return state, nil
    end
    return state, nil
  end

  if toEdge then
    -- Super+C copies; Super+V is handled by the terminal itself, which turns
    -- it into a bracketed paste, so there is nothing to bind for it here.
    if input == "c" then
      local from, to = M.selection(state)
      if from then return state, { type = "copy", text = state.text:sub(from + 1, to) } end
    end
    if input == "a" then
      return { text = state.text, cursor = #state.text, anchor = 0 }, nil
    end
    return state, nil
  end

  -- Ordinary printable input. Control characters are excluded explicitly:
  -- an unhandled Ctrl combination must not end up inserted as a literal byte.
  if input ~= "" and not input:match("^%c") then
    return replaceSelection(state, input), nil
  end

  return state, nil
end

return M
