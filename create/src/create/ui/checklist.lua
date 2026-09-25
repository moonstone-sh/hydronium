--[[
  hydronium_create.ui.checklist -- the post-submit task list: one line per
  enabled task ("write files", "moon sync", "install JS dependencies",
  "git init"), each showing a spinner while running, then a checkmark or a
  cross with its error. Pure `render(props)` -- wizard_app.lua owns the
  actual task state machine (create.wizard_tasks, run for real, not
  simulated) and the useAnimation-driven spinner frame.
]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")

local M = {}

local SPINNER_FRAMES = { "\226\160\139", "\226\160\153", "\226\160\185", "\226\160\184", "\226\160\188", "\226\160\180", "\226\160\164", "\226\160\166", "\226\160\167", "\226\160\135" } -- braille spinner
local CHECK, CROSS = "\226\156\148", "\226\156\150" -- ✔ ✖

--- @param tasks { label: string, status: "pending"|"running"|"done"|"error", error?: string }[]
--- @param spinner_frame integer
--- @return any element
function M.render(tasks, spinner_frame)
  local rows = {}
  for i, task in ipairs(tasks or {}) do
    local glyph, color
    if task.status == "done" then
      glyph, color = CHECK, "green"
    elseif task.status == "error" then
      glyph, color = CROSS, "red"
    elseif task.status == "running" then
      glyph, color = SPINNER_FRAMES[(spinner_frame % #SPINNER_FRAMES) + 1], "cyan"
    else
      glyph, color = "\194\183", "brightBlack" -- ·
    end
    rows[#rows + 1] = hydronium.h(ink.Box, { key = i, flexDirection = "row" },
      hydronium.h(ink.Text, { color = color }, glyph .. " "),
      hydronium.h(ink.Text, { dimColor = task.status == "pending" }, task.label))
    if task.status == "error" and task.error then
      rows[#rows + 1] = hydronium.h(ink.Text, { key = i .. "_err", color = "red" }, "    " .. tostring(task.error))
      rows[#rows + 1] = hydronium.h(ink.Text, { key = i .. "_hint", color = "brightBlack" }, "    check the error above and retry manually")
    end
  end
  return hydronium.h(ink.Box, { flexDirection = "column" }, rows)
end

return M
