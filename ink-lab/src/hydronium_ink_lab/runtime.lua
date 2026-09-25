local lab = require("hydronium_lab")
local session = require("hydronium_ink.session")
local snapshot = require("hydronium_ink_lab.snapshot")

local M = {}
local Runtime = {}
Runtime.__index = Runtime

function M.new(registry)
  if type(registry) ~= "table" or registry._kind ~= "hydronium.lab.registry" then
    error("hydronium_ink_lab.runtime: expected a hydronium_lab registry", 2)
  end
  return setmetatable({ registry = registry, active = nil, story = nil }, Runtime)
end

function Runtime:catalog()
  return { version = 1, stories = self.registry.manifest() }
end

function Runtime:open(id, options)
  options = options or {}
  local story = self.registry.get(id)
  if not story then error("hydronium_ink_lab.runtime: unknown story '" .. tostring(id) .. "'", 2) end
  if self.active then self.active:close() end
  local args = lab.copy(story.args)
  for key, value in pairs(options.args or {}) do args[key] = value end
  local size = story.sizes[1]
  self.story = story
  self.active = session.create(story.render(args), {
    columns = options.columns or size.columns,
    rows = options.rows or size.rows,
    color = options.color or story.color,
    -- Independent of `color` above (ANSI encoding depth) -- this is the
    -- color PROFILE control (adds "none"/NO_COLOR preview), so a story can
    -- be opened under any of truecolor/ansi256/ansi16/none regardless of
    -- what `color`/`story.color` says. Falls back to "auto" (real
    -- NO_COLOR/FORCE_COLOR detection), matching session.lua's own default,
    -- when neither the open request nor the story specifies one.
    colorProfile = options.colorProfile or story.colorProfile,
  })
  return snapshot.from_session(self.active)
end

function Runtime:_active()
  if not self.active then error("hydronium_ink_lab.runtime: no story is open", 3) end
  return self.active
end

function Runtime:request(request)
  if type(request) ~= "table" then error("hydronium_ink_lab.runtime: request must be a table", 2) end
  local op = request.op
  if op == "catalog" then return self:catalog() end
  if op == "open" then return self:open(request.story, request) end
  local active = self:_active()
  if op == "input" then
    active:dispatch({ type = "key", input = request.input or "", key = request.key or {} })
  elseif op == "bytes" then
    active:write(request.bytes or "")
  elseif op == "paste" then
    active:paste(request.text or "")
  elseif op == "resize" then
    active:resize(request.columns, request.rows)
  elseif op == "color" then
    active:setColorCapability(request.color)
  elseif op == "colorProfile" then
    -- The profile control: switches the SAME running story/session between
    -- truecolor/ansi256/ansi16/none live, so `ink.byProfile`/`ink.adaptive`
    -- prop values (and anything reading `hooks.useColorProfile()`) can be
    -- compared side by side without reopening the story.
    active:setColorProfile(request.colorProfile)
  elseif op == "step" then
    active:step(request.nowMs)
  elseif op == "interaction" then
    local found
    for _, interaction in ipairs(self.story.interactions) do
      if interaction.name == request.name then found = interaction break end
    end
    if not found then error("hydronium_ink_lab.runtime: unknown interaction '" .. tostring(request.name) .. "'", 2) end
    found.run(active)
    active:step(request.nowMs)
  elseif op == "snapshot" then
    -- No mutation.
  elseif op == "close" then
    active:close()
    self.active, self.story = nil, nil
    return { version = 1, closed = true }
  else
    error("hydronium_ink_lab.runtime: unsupported operation '" .. tostring(op) .. "'", 2)
  end
  return snapshot.from_session(active)
end

function Runtime:close()
  if self.active then self.active:close() end
  self.active, self.story = nil, nil
end

M.Runtime = Runtime
return M
