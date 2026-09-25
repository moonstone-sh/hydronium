-- Host-neutral story definitions and explicit registry composition.
local M = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function checkId(id, where)
  if type(id) ~= "string" or not id:match("^[%w][%w%._%-/]*$") then
    error(where .. ": id must be a non-empty portable story id", 3)
  end
end

local function normalizeSizes(sizes)
  if sizes == nil then return { { name = "default", columns = 80, rows = 24 } } end
  if type(sizes) ~= "table" or #sizes == 0 then
    error("hydronium_lab.story: sizes must be a non-empty array", 3)
  end
  local out, names = {}, {}
  for index, size in ipairs(sizes) do
    if type(size) ~= "table" then error("hydronium_lab.story: size " .. index .. " must be a table", 3) end
    local columns, rows = tonumber(size.columns), tonumber(size.rows)
    if not columns or columns < 1 or columns % 1 ~= 0 or not rows or rows < 1 or rows % 1 ~= 0 then
      error("hydronium_lab.story: size " .. index .. " needs positive integer columns and rows", 3)
    end
    local name = size.name or (columns .. "x" .. rows)
    if names[name] then error("hydronium_lab.story: duplicate size name '" .. name .. "'", 3) end
    names[name] = true
    out[index] = { name = name, columns = columns, rows = rows }
  end
  return out
end

local control_types = { text = true, number = true, boolean = true, select = true, color = true }
local COLOR_PROFILES = { truecolor = true, ansi256 = true, ansi16 = true, none = true }

--- @param value? "truecolor"|"ansi256"|"ansi16"|"none"
--- @return "truecolor"|"ansi256"|"ansi16"|"none"|nil
local function normalizeColorProfile(value, where)
  if value == nil then return nil end
  if not COLOR_PROFILES[value] then
    error(where .. ": colorProfile must be truecolor, ansi256, ansi16, or none", 3)
  end
  return value
end

local function json_value(value, seen, where)
  local kind = type(value)
  if kind == "nil" or kind == "string" or kind == "boolean" then return copy(value) end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error(where .. ": numbers must be finite", 4)
    end
    return value
  end
  if kind ~= "table" then error(where .. ": values must be JSON-shaped", 4) end
  if getmetatable(value) ~= nil then error(where .. ": metatables are not supported", 4) end
  seen = seen or {}
  if seen[value] then error(where .. ": cyclic tables are not supported", 4) end
  seen[value] = true
  local out, count, array = {}, 0, true
  for key, item in pairs(value) do
    count = count + 1
    if type(key) ~= "string" and (type(key) ~= "number" or key < 1 or key % 1 ~= 0) then
      error(where .. ": object keys must be strings and array indexes positive integers", 4)
    end
    if type(key) ~= "number" then array = false end
    out[key] = json_value(item, seen, where)
  end
  if array then
    for index = 1, count do
      if value[index] == nil then error(where .. ": arrays must be dense", 4) end
    end
  end
  seen[value] = nil
  return out
end

local function normalizeControls(controls)
  if controls == nil then return {} end
  if type(controls) ~= "table" then error("hydronium_lab: controls must be a table", 3) end
  local out = {}
  for name, control in pairs(controls) do
    if type(name) ~= "string" or name == "" then error("hydronium_lab: control names must be non-empty strings", 3) end
    if type(control) ~= "table" or not control_types[control.type] then
      error("hydronium_lab: control '" .. name .. "' needs type text, number, boolean, select, or color", 3)
    end
    local normalized = json_value(control, {}, "hydronium_lab: control '" .. name .. "'")
    if normalized.type == "select" and (type(normalized.options) ~= "table" or #normalized.options == 0) then
      error("hydronium_lab: select control '" .. name .. "' needs non-empty options", 3)
    end
    out[name] = normalized
  end
  return out
end

--- @class hydronium_lab.StorySpec
--- @field id string
--- @field title? string
--- @field render fun(args: table): LuaxElement
--- @field args? table
--- @field sizes? {name?: string, columns: integer, rows: integer}[]
--- @field color? "ansi16"|"ansi256"|"truecolor"
--- @field colorProfile? "truecolor"|"ansi256"|"ansi16"|"none" Default color
---   PROFILE this story opens under (see hydronium_ink.color's own doc
---   comment for how this differs from `color` above -- that one picks the
---   ANSI encoding depth, this is the superset a component actually reads
---   via `hydronium_ink.hooks.useColorProfile()`/`ink.byProfile`, and adds
---   "none"). Unset means "auto" -- real NO_COLOR/FORCE_COLOR detection,
---   same as a session created with no `colorProfile` option at all. A
---   host that runs stories interactively can send an `op = "colorProfile"`
---   request (hydronium_ink_lab.runtime) at any time to preview the SAME
---   open story under a different profile, independent of this default.
--- @field interactions? {name: string, run: fun(session: table)}[]

function M.story(spec)
  if type(spec) ~= "table" then error("hydronium_lab.story: expected a table", 2) end
  checkId(spec.id, "hydronium_lab.story")
  if type(spec.render) ~= "function" then error("hydronium_lab.story: render must be a function", 2) end
  local color = spec.color or "truecolor"
  if color ~= "ansi16" and color ~= "ansi256" and color ~= "truecolor" then
    error("hydronium_lab.story: color must be ansi16, ansi256, or truecolor", 2)
  end
  local colorProfile = normalizeColorProfile(spec.colorProfile, "hydronium_lab.story")
  local interactions, interactionNames = {}, {}
  for index, interaction in ipairs(spec.interactions or {}) do
    if type(interaction) ~= "table" or type(interaction.name) ~= "string" or type(interaction.run) ~= "function" then
      error("hydronium_lab.story: interaction " .. index .. " needs name and run", 2)
    end
    if interactionNames[interaction.name] then
      error("hydronium_lab.story: duplicate interaction '" .. interaction.name .. "'", 2)
    end
    interactionNames[interaction.name] = true
    interactions[index] = { name = interaction.name, run = interaction.run }
  end
  return {
    _kind = "hydronium.lab.story",
    id = spec.id,
    title = spec.title or spec.id,
    render = spec.render,
    args = copy(spec.args or {}),
    controls = normalizeControls(spec.controls),
    group = spec.group,
    description = spec.description,
    source = spec.source and copy(spec.source) or nil,
    sizes = normalizeSizes(spec.sizes),
    color = color,
    colorProfile = colorProfile,
    interactions = interactions,
  }
end

--- Define the value returned by a convention-based `*.stories.lua[x]` file.
--- IDs remain unbound until a discovery host supplies the normalized file
--- stem, keeping filesystem policy outside this host-neutral package.
function M.collection(spec)
  if type(spec) ~= "table" then error("hydronium_lab.collection: expected a table", 2) end
  if type(spec.stories) ~= "table" or next(spec.stories) == nil then
    error("hydronium_lab.collection: stories must be a non-empty table", 2)
  end
  if spec.component == nil and spec.render == nil then
    error("hydronium_lab.collection: component or render is required", 2)
  end
  local stories = {}
  for key, value in pairs(spec.stories) do
    if type(key) ~= "string" or not key:match("^[a-z0-9][a-z0-9%-]*$") then
      error("hydronium_lab.collection: story keys must be portable lowercase slugs", 2)
    end
    if type(value) ~= "table" then error("hydronium_lab.collection: story '" .. key .. "' must be a table", 2) end
    stories[key] = copy(value)
  end
  return {
    _kind = "hydronium.lab.collection",
    title = spec.title,
    component = spec.component,
    render = spec.render,
    args = json_value(spec.args or {}, {}, "hydronium_lab.collection: args"),
    controls = normalizeControls(spec.controls),
    sizes = spec.sizes and normalizeSizes(spec.sizes) or nil,
    color = spec.color,
    colorProfile = normalizeColorProfile(spec.colorProfile, "hydronium_lab.collection"),
    stories = stories,
  }
end

function M.registry(entries)
  if type(entries) ~= "table" then error("hydronium_lab.registry: expected an array", 2) end
  local stories, byId = {}, {}
  local function add(entry)
    if type(entry) == "table" and entry._kind == "hydronium.lab.registry" then
      for _, nested in ipairs(entry.stories) do add(nested) end
      return
    end
    if type(entry) ~= "table" or entry._kind ~= "hydronium.lab.story" then
      error("hydronium_lab.registry: entries must be stories or registries", 3)
    end
    if byId[entry.id] then error("hydronium_lab.registry: duplicate story id '" .. entry.id .. "'", 3) end
    stories[#stories + 1], byId[entry.id] = entry, entry
  end
  for _, entry in ipairs(entries) do add(entry) end
  if #stories == 0 then error("hydronium_lab.registry: at least one story is required", 2) end
  return {
    _kind = "hydronium.lab.registry",
    stories = stories,
    get = function(id) return byId[id] end,
    manifest = function()
      local result = {}
      for index, story in ipairs(stories) do
        local interactions = {}
        for i, interaction in ipairs(story.interactions) do interactions[i] = interaction.name end
        result[index] = {
          id = story.id, title = story.title, args = copy(story.args), sizes = copy(story.sizes),
          color = story.color, colorProfile = story.colorProfile,
          interactions = interactions, controls = copy(story.controls or {}),
          group = story.group, description = story.description, source = copy(story.source),
        }
      end
      return result
    end,
  }
end

M.copy = copy
M.discovery = require("hydronium_lab.discovery")
M.host = require("hydronium_lab.host")
return M
