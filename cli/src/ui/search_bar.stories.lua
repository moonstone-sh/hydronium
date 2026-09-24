--[[
  Stories for the filter bar and its chips.

  These exist because the specs for this component assert on the painted CELL
  GRID -- that a chip label survives a row break, that no character is lost at
  any caret position. Those assertions are correct and completely unreadable:
  nothing in them tells you whether the chip is legible, whether the caret is
  visible against a selection, or whether the colours work. A story does.

  The `wrapping` story is the one worth opening first. Chips are Boxes, a Box
  is a flex item, and Yoga never splits a flex item -- so narrowing the
  terminal moves a whole chip to the next row rather than tearing it in half.
  That is asserted in cli/tests/search_bar_spec.lua and is much easier to
  believe when you can drag the width.
--]]

local lab = require("hydronium_lab")
local field = require("ui.search_field")
local query = require("query")
local search_bar = require("ui.search_bar")

--- Builds field state from story args, clamping the caret so a controls-panel
--- edit can never produce an out-of-range cursor.
--- @param args table
--- @return table
local function state_from(args)
  local state = field.new_state(args.text or "")
  local cursor = tonumber(args.cursor)
  state.cursor = cursor and math.max(0, math.min(math.floor(cursor), #state.text)) or #state.text
  local anchor = tonumber(args.anchor)
  if anchor then
    state.anchor = math.max(0, math.min(math.floor(anchor), #state.text))
  end
  return state
end

return lab.collection({
  title = "CLI/Filter bar",

  render = function(args)
    local state = state_from(args)
    return search_bar.render(state, query.tokenize(state.text), { focused = args.focused })
  end,

  controls = {
    text = { type = "text" },
    focused = { type = "boolean" },
    cursor = { type = "number" },
    anchor = { type = "number" },
  },

  sizes = {
    { name = "wide", columns = 100, rows = 6 },
    { name = "narrow", columns = 56, rows = 8 },
    { name = "cramped", columns = 34, rows = 10 },
  },

  stories = {
    -- Nothing typed: the bar shows its own syntax as a hint rather than an
    -- empty box, since an empty filter bar teaches nobody the language.
    empty = { args = { text = "", focused = false } },

    -- One recognised tag, caret elsewhere, so it renders as a chip.
    chip = { args = { text = "method:GET", focused = false } },

    -- Every chip state side by side: recognised, negated, and a field that
    -- does not exist. The unknown one must LOOK wrong while you type it.
    ["chip-states"] = {
      args = { text = "method:GET -status:5xx nope:1 plain-text", focused = false },
    },

    -- The caret inside a token renders it as RAW TEXT, not a chip: a chip has
    -- nowhere sensible to put a caret. Move the caret out and it snaps back.
    ["editing-a-token"] = {
      args = { text = "method:GET status:200", focused = true, cursor = 4 },
    },

    -- Caret past the last token, which is what typing at the end looks like.
    ["caret-at-end"] = {
      args = { text = "method:GET ", focused = true, cursor = 11 },
    },

    -- A selection, as Shift+Left produces. Needs the Kitty keyboard protocol
    -- in a real terminal; here it is just state.
    selection = {
      args = { text = "method:GET status:200", focused = true, cursor = 21, anchor = 11 },
    },

    -- Open this at the `cramped` size. Six chips cannot fit on one row, and
    -- each one moves whole.
    wrapping = {
      args = {
        text = "method:GET status:200 path:/api mime:json origin:local ip:127",
        focused = false,
      },
    },

    -- A quoted value keeps its spaces and stays one chip.
    ["quoted-value"] = {
      args = { text = 'body:"user not found" status:4xx', focused = false },
    },
  },
})
