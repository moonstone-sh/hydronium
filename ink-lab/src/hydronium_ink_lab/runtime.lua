local lab = require("hydronium_lab")
local session = require("hydronium_ink.session")
local snapshot = require("hydronium_ink_lab.snapshot")
local frame = require("hydronium_ink_lab.frame")

local M = {}
local Runtime = {}
Runtime.__index = Runtime

-- Ops that can change the canvas itself (dimensions, color capability/
-- profile) or that a client uses to force a resync (`snapshot`). Every other
-- op -- `step`, `input`, `bytes`, `paste`, `interaction` -- is encoded as a
-- delta against the previous frame this session sent.
local FULL_FRAME_OPS = { open = true, resize = true, colorProfile = true, color = true, snapshot = true }

function M.new(registry)
  if type(registry) ~= "table" or registry._kind ~= "hydronium.lab.registry" then
    error("hydronium_ink_lab.runtime: expected a hydronium_lab registry", 2)
  end
  return setmetatable({ registry = registry, active = nil, story = nil, frame_stream = frame.new_stream() }, Runtime)
end

function Runtime:catalog()
  return { version = 1, stories = self.registry.manifest() }
end

function Runtime:open(id, options)
  options = options or {}
  local story = self.registry.get(id)
  if not story then error("hydronium_ink_lab.runtime: unknown story '" .. tostring(id) .. "'", 2) end
  local defaults = lab.copy(story.args)
  for name, control in pairs(story.controls) do if defaults[name] == nil and control.default ~= nil then defaults[name] = lab.copy(control.default) end end
  local args = lab.copy(defaults)
  for key, value in pairs(options.args or {}) do args[key] = value end
  local size = story.sizes[1]
  local nextState = lab.state.new(args, story.controls, defaults)
  if options.playing ~= nil and type(options.playing) ~= "boolean" then error("hydronium_ink_lab: playing must be boolean", 2) end
  if self.active then self.active:close() end
  self.output = {}
  self.story = story
  self.state = nextState
  self.nowMs, self.playing, self.frameIndex, self.intervalMs = 0, options.playing ~= false, 0, 1000 / 60
  self:_playback()
  local function Preview()
    return function() return story.render(self.state.args()) end
  end
  local element = require("hydronium").h(lab.state.Context.Provider, { value = self.state }, require("hydronium").h(Preview))
  self.active = session.create(element, {
    inline = "auto",
    writeFn = function(bytes) self.output[#self.output + 1] = bytes end,
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
  -- A newly opened story is a fresh canvas: nothing about its previous
  -- style table or frame sequence carries any meaning forward, so start
  -- both over rather than let ids accumulate across story switches within
  -- one long-lived Lab session.
  self.frame_stream = frame.new_stream()
  self.active:step(0) -- Establish ticker epochs before the first inspected frame.
  return self:_emit(true)
end

--- Encodes the active session's current frame against `self.frame_stream`,
--- forcing a full (self-contained) frame when `force_full` is set.
function Runtime:_playback()
  if self.state then self.state.setPlayback({ nowMs = self.nowMs, playing = self.playing, frame = self.frameIndex, intervalMs = self.intervalMs }) end
end
function Runtime:_advance(nowMs)
  if not lab.state.finite(nowMs) or nowMs < self.nowMs then error("hydronium_ink_lab: time must be finite and monotonic", 2) end
  self.nowMs = nowMs
  self.frameIndex = self.frameIndex + 1
  self:_playback()
  self.active:step(nowMs)
end
function Runtime:_emit(force_full)
  local raw = snapshot.from_session(self.active)
  local encoded = frame.encode(self.frame_stream, raw, force_full)
  encoded.ansi = table.concat(self.output or {})
  self.output = {}
  local host = self.active._host
  encoded.terminal = { columns = host._cols, rows = host._rows, inline = host._inline, scrollable = raw.height > math.max(host._rows - 2, 1) }
  encoded.focus = host._scrollFocus or false
  encoded.lab = { args = lab.copy(self.state.args()), playback = lab.copy(self.state.playback()) }
  return encoded
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
  if op == "restart" then
    local active = self:_active()
    return self:open(self.story.id, { args = self.state.args(), columns = active._host._cols, rows = active._host._rows,
      color = active._host._colorCapability, colorProfile = active._host._colorProfile, playing = false })
  end
  local active = self:_active()
  if op == "input" then
    active:dispatch({ type = "key", input = request.input or "", key = request.key or {} })
  elseif op == "bytes" then
    active:write(request.bytes or "")
  elseif op == "scroll" then
    local lines = request.lines
    if type(lines) ~= "number" or lines % 1 ~= 0 or math.abs(lines) > 10000 then
      error("hydronium_ink_lab.runtime: scroll lines must be an integer between -10000 and 10000", 2)
    end
    if lines ~= 0 then active:dispatch({ type = "key", input = "", key = {
      pageUp = lines < 0, pageDown = lines > 0, scrollRows = math.abs(lines),
    } }) end
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
  elseif op == "args" then
    self.state.setArgs(request.args)
    active:_flush()
  elseif op == "resetArgs" then
    self.state.resetArgs()
    active:_flush()
  elseif op == "playback" then
    if request.playing ~= nil and type(request.playing) ~= "boolean" then error("hydronium_ink_lab: playing must be boolean", 2) end
    if request.intervalMs ~= nil and (not lab.state.finite(request.intervalMs) or request.intervalMs <= 0) then error("hydronium_ink_lab: interval must be positive and finite", 2) end
    if request.playing ~= nil then
      self.playing = request.playing
    end
    if request.intervalMs ~= nil then
      self.intervalMs = request.intervalMs
    end
    self:_playback()
    active:_flush()
  elseif op == "seek" then
    if not lab.state.finite(request.nowMs) or request.nowMs < self.nowMs then error("hydronium_ink_lab: seek only advances; restart to inspect earlier frames", 2) end
    self.playing = false
    self:_advance(request.nowMs)
  elseif op == "advance" then
    self.playing = false
    self:_advance(self.nowMs + self.intervalMs)
  elseif op == "step" then
    if self.playing then self:_advance(request.nowMs or (self.nowMs + self.intervalMs)) end
  elseif op == "interaction" then
    local found
    for _, interaction in ipairs(self.story.interactions) do
      if interaction.name == request.name then found = interaction break end
    end
    if not found then error("hydronium_ink_lab.runtime: unknown interaction '" .. tostring(request.name) .. "'", 2) end
    found.run(active)
    active:step(self.nowMs)
  elseif op == "snapshot" then
    active._host.invalidate()
    active._host.flush()
  elseif op == "close" then
    active:close()
    self.active, self.story = nil, nil
    return { version = 1, closed = true }
  else
    error("hydronium_ink_lab.runtime: unsupported operation '" .. tostring(op) .. "'", 2)
  end
  return self:_emit(FULL_FRAME_OPS[op] or false)
end

function Runtime:close()
  if self.active then self.active:close() end
  self.active, self.story = nil, nil
end

M.Runtime = Runtime
return M
