--[[
  hydronium_create.ui.field -- pure row-builders for the wizard's three
  field shapes: a free-text input, a single-choice radio group, and a
  yes/no toggle. Each function returns a plain array of ink elements, one
  per rendered LINE -- wizard_app.lua wraps every line with the left-rail
  prefix itself (see that file's own header comment for why rail wrapping
  happens one level up instead of inside these functions: the rail is a
  property of the group's position in the form, not of any one field
  shape).

  Every field carries a plain LABEL (e.g. "name", "framework", "package
  manager") -- inline with the value for a text field, on its own line
  above the options for a radio group. Labels are always plain (never
  colored), per the wizard's own voice guideline: chemistry puns live in
  headings/status only, never on a field name.

  Shared "choices" rules implemented here, per the wizard's design spec:
    - every alternative is always visible, never hidden behind scrolling
      through a list one at a time
    - a recommended option gets a trailing " ★"
    - each option is followed by its own description on the line BELOW
      (dim), then a reserved blank line -- "option / description / space"
      -- ALWAYS its own real description, even when disabled (see
      field-level vs. per-option disabling below for what changes instead)
    - an option that is NOT the active selection renders with
      strikethrough+dim, UNLESS this field is the one currently being
      edited (`active`), in which case every alternative renders plainly
      so the user can actually compare them before picking. This is what
      makes the form's OWN scrollback read as "here is the path I took"
      once you've moved on, while still showing every real choice while
      you're the one choosing (see wizard_app.lua's own field-focus
      handling for how `active` is computed).
    - TWO KINDS of "disabled", never conflated:
        1. field-level (`field_disabled`/`field_disabled_reason`): the
           WHOLE field is currently moot (e.g. router when SSR always
           uses Hydronium Router; package manager when Tailwind is off).
           Every option renders dim+struck, keeps its OWN description
           (dimmed), and the reason is shown exactly ONCE, right under
           the field label -- never repeated per option.
        2. per-option (`opt.disabled`/`opt.disabled_reason`): the FIELD
           itself is live, but this ONE alternative isn't available right
           now (e.g. a package manager not found on PATH, or Lua 5.4 when
           the framework requires LuaJIT). That option alone renders
           dim+struck with its OWN disabling reason in place of its
           description; every other option in the field stays normal.
]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")

local M = {}

local RADIO_ON, RADIO_OFF = "\226\151\137", "\226\151\139" -- ◉ ○
local TOGGLE_ON, TOGGLE_OFF = "\226\150\163", "\226\150\161" -- ▣ □
local STAR = " \226\152\133" -- " ★"
local CURSOR = "\226\150\141" -- ▍ (matches the wizard spec's own worked example)

-- Text-field labels ("name", "directory") are padded to this width so
-- their values line up in a column -- the widest label ("directory") plus
-- two trailing spaces.
local LABEL_WIDTH = 11

--- @param props { label: string, value: string, placeholder?: string, caret?: boolean, hint?: string, error?: string, group_dim?: boolean }
--- @return any[] rows
--- An empty value shows `placeholder` (dim) instead, with the cursor still
--- appended when this field is active -- never a bare blank line.
function M.text_field_rows(props)
  props = props or {}
  local value = props.value or ""
  local gd = props.group_dim or false
  local showing_placeholder = value == "" and props.placeholder ~= nil
  local caret = hydronium.h(ink.Text, { key = "caret", dimColor = gd },
    props.caret ~= false and CURSOR or "")
  local label_text = string.format("%-" .. LABEL_WIDTH .. "s", props.label or "")
  local rows = {
    hydronium.h(ink.Box, { key = "value", flexDirection = "row" },
      hydronium.h(ink.Text, { key = "lbl", dimColor = gd }, label_text),
      hydronium.h(ink.Text, { key = "v", bold = not gd and not showing_placeholder, dimColor = gd or showing_placeholder },
        showing_placeholder and props.placeholder or value),
      caret),
  }
  if props.error then
    rows[#rows + 1] = hydronium.h(ink.Text, { key = "err", color = "red", dimColor = gd }, string.rep(" ", LABEL_WIDTH) .. props.error)
  elseif props.hint then
    rows[#rows + 1] = hydronium.h(ink.Text, { key = "hint", color = "brightBlack" }, string.rep(" ", LABEL_WIDTH) .. props.hint)
  end
  rows[#rows + 1] = hydronium.h(ink.Newline, { key = "gap" })
  return rows
end

--- @param opt { id: string, label: string, description?: string, recommended?: boolean, disabled?: boolean, disabled_reason?: string }
--- @param selected boolean
--- @param active boolean whether the OWNING FIELD is the one currently focused.
--- @param field_disabled boolean whether the WHOLE field (not just this option) is currently moot.
--- @return any[] rows (marker+label row, description row, blank row)
local function option_rows(opt, selected, active, key_prefix, group_dim, field_disabled)
  local option_disabled = field_disabled or opt.disabled
  local struck = option_disabled or (not active and not selected)
  local dim = struck or option_disabled or group_dim
  local marker = selected and RADIO_ON or RADIO_OFF
  local label_children = {
    hydronium.h(ink.Text, { key = "m", strikethrough = struck, dimColor = dim }, marker .. " "),
    hydronium.h(ink.Text, { key = "l", strikethrough = struck, dimColor = dim, bold = selected and not struck and not group_dim },
      opt.label),
  }
  if opt.recommended then
    label_children[#label_children + 1] = hydronium.h(ink.Text, { key = "star", color = "yellow", strikethrough = struck, dimColor = group_dim }, STAR)
  end
  local rows = { hydronium.h(ink.Box, { key = key_prefix .. "_label", flexDirection = "row" }, label_children) }
  -- field_disabled: always the option's OWN description (dimmed), never
  -- the field-level reason repeated per option (that prints once, above
  -- the options -- see radio_group_rows). A per-option disable (not
  -- field-wide) still shows ITS OWN reason in place of the description.
  local sub = (not field_disabled and opt.disabled) and opt.disabled_reason or opt.description
  if sub then
    rows[#rows + 1] = hydronium.h(ink.Text, {
      key = key_prefix .. "_desc",
      color = (not field_disabled and opt.disabled) and "yellow" or "brightBlack",
      dimColor = field_disabled or not opt.disabled,
    }, "  " .. sub)
  end
  rows[#rows + 1] = hydronium.h(ink.Newline, { key = key_prefix .. "_gap" })
  return rows
end

--- @param props { field_label: string, options: table[], selected_id: string, active: boolean, field_disabled?: boolean, field_disabled_reason?: string, group_dim?: boolean }
--- @return any[] rows
--- Each `opt` may carry a `subgroup` label (e.g. "Vite-based" / "No Vite"
--- on the wizard's framework choice) -- a dim, italic header line is
--- inserted right before the first option of each distinct subgroup, in
--- the order they appear, so related alternatives cluster visually
--- without changing the "every option always visible" contract at all
--- (a subgroup header is purely a label between existing rows, never a
--- collapse/hide).
function M.radio_group_rows(props)
  props = props or {}
  local gd = props.group_dim or false
  local rows = {}
  if props.field_label then
    rows[#rows + 1] = hydronium.h(ink.Text, { key = "label", bold = not gd, dimColor = gd }, props.field_label)
  end
  if props.field_disabled and props.field_disabled_reason then
    rows[#rows + 1] = hydronium.h(ink.Text, { key = "field_reason", color = "yellow", dimColor = true }, "(" .. props.field_disabled_reason .. ")")
  end
  local last_subgroup = nil
  for i, opt in ipairs(props.options or {}) do
    if opt.subgroup and opt.subgroup ~= last_subgroup then
      rows[#rows + 1] = hydronium.h(ink.Text, { key = "subgroup" .. i, italic = true, dimColor = true }, opt.subgroup)
      last_subgroup = opt.subgroup
    end
    local selected = opt.id == props.selected_id
    for _, row in ipairs(option_rows(opt, selected, props.active, "opt" .. i, gd, props.field_disabled)) do
      rows[#rows + 1] = row
    end
  end
  return rows
end

--- @param props { label: string, description?: string, value: boolean, active: boolean, disabled?: boolean, disabled_reason?: string, group_dim?: boolean }
--- @return any[] rows
function M.toggle_rows(props)
  props = props or {}
  local dim = (props.disabled and not props.value) or props.group_dim
  local marker = props.value and TOGGLE_ON or TOGGLE_OFF
  local rows = {
    hydronium.h(ink.Box, { key = "label", flexDirection = "row" },
      hydronium.h(ink.Text, { key = "m", dimColor = dim, bold = props.value and not props.group_dim }, marker .. " "),
      hydronium.h(ink.Text, { key = "l", dimColor = dim, bold = props.value and not props.group_dim }, props.label)),
  }
  local sub = props.disabled and props.disabled_reason or props.description
  if sub then
    rows[#rows + 1] = hydronium.h(ink.Text, { key = "desc", color = props.disabled and "yellow" or "brightBlack", dimColor = not props.disabled }, "  " .. sub)
  end
  rows[#rows + 1] = hydronium.h(ink.Newline, { key = "gap" })
  return rows
end

return M
