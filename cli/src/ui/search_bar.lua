--[[
  hydronium_cli.ui.search_bar -- renders the filter field as chips.

  A recognised `field:value` draws as a two-tone chip: the field on a vibrant
  background in white, the value on a muted background beside it. An
  unrecognised field draws in the same shape but in a warning colour, so a
  typo LOOKS wrong while you type instead of silently filtering everything
  away.

  THE TOKEN UNDER THE CARET IS NOT CHIPPED. It renders as raw text with the
  caret in it. A chip has no sensible place to put a caret, and "the thing I
  am editing looks like text, the things I finished look like chips" is the
  behaviour every real tag input has. Move the caret away and the token snaps
  into a chip.

  WRAPPING is handled by flex, not by this module. Each chip is a Box, and a
  Box is a flex item; Yoga never splits a flex item, so a chip either fits on
  the current row or moves to the next one whole. That is why the container
  below sets `flexWrap = "wrap"` and nothing here measures text: atomic
  wrapping falls out of the layout engine rather than being re-implemented.
--]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local query = require("query")
local search_field = require("ui.search_field")

local M = {}

--- The bar's focus id. A stable constant rather than a generated one so the
--- `/` binding elsewhere can focus it by name without having to be handed a
--- reference through props.
M.FOCUS_ID = "hydronium-cli.filter"

--- Chip colours. Drawn from the 8-colour set the terminal host speaks (see
--- host/terminal.lua) so they render identically everywhere rather than
--- depending on a 256-colour palette.
M.COLORS = {
  tag_field_bg = "blue",
  tag_field_fg = "white",
  tag_value_bg = "white",
  tag_value_fg = "black",
  unknown_field_bg = "yellow",
  unknown_field_fg = "black",
}

--- @param token table A hydronium_cli.QueryToken
--- @param key integer
--- @return table element
local function chip(token, key)
  local known = token.type == "tag"
  local label = (token.negated and "-" or "") .. token.field .. ":"
  return hydronium.h(ink.Box, { key = key, flexDirection = "row" },
    hydronium.h(ink.Text, {
      backgroundColor = known and M.COLORS.tag_field_bg or M.COLORS.unknown_field_bg,
      color = known and M.COLORS.tag_field_fg or M.COLORS.unknown_field_fg,
      bold = true,
    }, " " .. label .. " "),
    hydronium.h(ink.Text, {
      backgroundColor = M.COLORS.tag_value_bg,
      color = M.COLORS.tag_value_fg,
    }, " " .. (token.value ~= "" and token.value or "\226\128\166") .. " ")
  )
end

--- Raw text with a caret rendered as an inverted cell.
---
--- The caret is drawn rather than placed with a real terminal cursor because
--- the host parks the hardware cursor below the frame after every changed
--- paint (see useCursor's own doc comment) -- a cursor positioned into the
--- field would be moved away again on the very next repaint.
--- @param text string
--- @param caret integer|nil 0-based offset within `text`, or nil
--- @param key integer
--- @param selFrom integer|nil
--- @param selTo integer|nil
--- @return table element
local function rawText(text, caret, key, selFrom, selTo)
  local parts = {}
  local function push(str, props)
    if str ~= "" then
      parts[#parts + 1] = hydronium.h(ink.Text, props or {}, str)
    end
  end

  if selFrom and selTo and selTo > selFrom then
    push(text:sub(1, selFrom))
    push(text:sub(selFrom + 1, selTo), { backgroundColor = "cyan", color = "black" })
    push(text:sub(selTo + 1))
  elseif caret then
    push(text:sub(1, caret))
    -- The caret sits ON the next character, or on a trailing space when it is
    -- at the very end -- otherwise an end-of-input caret would be invisible.
    local under = text:sub(caret + 1, caret + 1)
    push(under ~= "" and under or " ", { backgroundColor = "white", color = "black" })
    push(text:sub(caret + 2))
  else
    push(text)
  end

  return hydronium.h(ink.Box, { key = key, flexDirection = "row" }, parts)
end

--- Builds the filter bar.
--- @param state hydronium_cli.SearchFieldState
--- @param tokens table[] From query.tokenize(state.text)
--- @param opts table|nil `{ focused = boolean }`
--- @return table element
function M.render(state, tokens, opts)
  opts = opts or {}
  local caret = opts.focused and state.cursor or nil
  local selFrom, selTo = nil, nil
  if opts.focused then
    local f, t = state.anchor and math.min(state.anchor, state.cursor), state.anchor and math.max(state.anchor, state.cursor)
    if f and t and t > f then selFrom, selTo = f, t end
  end

  local children = {}
  local key = 0
  local consumed = 0

  for _, token in ipairs(tokens) do
    key = key + 1
    -- Whitespace between tokens is preserved so the rendered bar matches the
    -- text the caret arithmetic is computed against.
    if token.from > consumed + 1 then
      children[#children + 1] =
        hydronium.h(ink.Text, { key = "gap" .. key }, state.text:sub(consumed + 1, token.from - 1))
    end

    local caretInside = caret and caret >= token.from - 1 and caret <= token.to
    local selectionTouches = selFrom and selTo and not (selTo <= token.from - 1 or selFrom >= token.to)

    if token.type == "text" or caretInside or selectionTouches then
      local localCaret = caretInside and (caret - (token.from - 1)) or nil
      local lf = selectionTouches and math.max(0, selFrom - (token.from - 1)) or nil
      local lt = selectionTouches and math.min(#token.text, selTo - (token.from - 1)) or nil
      children[#children + 1] = rawText(token.text, localCaret, key, lf, lt)
    else
      children[#children + 1] = chip(token, key)
    end
    consumed = token.to
  end

  -- A caret sitting past the last token (typing at the end) still needs to be
  -- drawn, or the field looks unfocused exactly when it is focused.
  if caret and caret >= consumed then
    children[#children + 1] = rawText(state.text:sub(consumed + 1), caret - consumed, key + 1)
  end

  if #children == 0 then
    children[#children + 1] = hydronium.h(ink.Text, { dimColor = true },
      "filter: method:GET  -status:2xx  duration:>100  body:\"not found\"")
  end

  return hydronium.h(ink.Box, { flexDirection = "row", flexWrap = "wrap" }, children)
end

--- The bar as a real focusable component.
---
--- Its key handling is bound to its own focus id, so it is offered input ONLY
--- while focused, and it stops propagation on everything it takes. That is
--- what keeps `q` from quitting and `f` from leaving the view while you are
--- typing a filter -- and it holds without any handler elsewhere knowing this
--- component exists, because ordering comes from the tree and the gate comes
--- from focus.
--- @param state table The CLI ui state (see ui/app.lua's new_state).
--- @return function component
function M.create(state)
  return function()
    local focus = hooks.useFocus({ id = M.FOCUS_ID })
    local manager = hooks.useFocusManager()
    local clipboard = hooks.useClipboard()

    hooks.useInput(function(input, key, evt)
      key = key or {}
      evt.stop()
      if key.escape or key["return"] then
        -- Enter commits by blurring; the filter is already live, since it
        -- reapplies on every keystroke.
        manager.blur()
        return
      end
      local next_state, intent = search_field.handle_key(state.search(), { input = input, key = key })
      state.set_search(next_state)
      state.set_search_revision(state.search_revision() + 1)
      if intent and intent.type == "copy" then
        clipboard.write(intent.text)
      end
    end, { focusId = focus.id })

    hooks.usePaste(function(text, evt)
      evt.stop()
      state.set_search(search_field.handle_key(state.search(), { type = "paste", text = text }))
      state.set_search_revision(state.search_revision() + 1)
    end, { focusId = focus.id })

    return function()
      state.search_revision()
      local field_state = state.search()
      return hydronium.h(ink.Box, { flexDirection = "row" },
        hydronium.h(ink.Text, { dimColor = not focus.isFocused() }, " / "),
        M.render(field_state, query.tokenize(field_state.text), { focused = focus.isFocused() }))
    end
  end
end

return M
