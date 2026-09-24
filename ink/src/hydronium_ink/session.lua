-- Deterministic, non-blocking Ink application driver. A session owns the
-- reconciler, hook registries, parser and terminal frame, but no stdin, clock,
-- terminal modes or event loop. Native renderers and development tools supply
-- those effects and advance the session explicitly.
local hydronium = require("hydronium")
local reconcilerModule = require("hydronium.core.reconciler")
local scheduler = require("hydronium.core.scheduler")
local terminalHost = require("hydronium_ink.host.terminal")
local hooks = require("hydronium_ink.hooks")
local keys = require("hydronium_ink.keys")
-- Wall-clock (gettimeofday), NOT os.clock()'s CPU time -- see Session:step.
local clock = require("hydronium_ink.clock")

local M = {}
local Session = {}
Session.__index = Session

local function removeIdentity(list, value)
  for i, entry in ipairs(list) do
    if entry == value then
      table.remove(list, i)
      return
    end
  end
end

local function positiveInteger(value, fallback)
  value = tonumber(value)
  if not value or value < 1 then return fallback end
  return math.floor(value)
end

--- @class hydronium_ink.SessionOptions
--- @field columns? integer Initial terminal width. Default 80.
--- @field rows? integer Initial terminal height. Default 24.
--- @field color? "auto"|"ansi16"|"ansi256"|"truecolor"
--- @field hyperlinks? boolean|"auto" Whether `<Text href>` emits real OSC 8
---   escapes. Default "auto" (NO_COLOR/TERM/TERM_PROGRAM-based detection,
---   see hydronium_ink.host.terminal's "Hyperlink capability" section) --
---   deliberately NOT tied to `color` above, since OSC 8 support does not
---   correlate with color depth support.
--- @field exitOnCtrlC? boolean Default true.
--- @field writeFn? fun(bytes: string) Optional ANSI sink. The Lab normally omits it.
--- @field onCursor? fun(position: {x: integer, y: integer}|nil)
--- @field onAltScreen? fun(enabled: boolean)
--- @field onTitle? fun(title: string) See hydronium_ink.hooks.useTerminalTitle.
--- @field onClipboardWrite? fun(text: string) See hydronium_ink.hooks.useClipboard.
--- @field onTick? fun(nowMs: number)

--- @param element LuaxElement
--- @param opts? hydronium_ink.SessionOptions
function M.create(element, opts)
  opts = opts or {}
  local self = setmetatable({}, Session)
  self._closed = false
  self._exited = false
  self._exitReason = nil
  self._cursor = nil
  self._altScreen = false
  self._title = ""
  self._lastClipboardWrite = nil
  self._handlers = {}
  self._pasteHandlers = {}
  self._focusEntries = {}
  self._tickers = {}
  self._pendingWrites = {}
  self._nextHandlerId = 0
  self._nextPasteHandlerId = 0
  self._nextFocusId = 0
  self._parser = keys.newParser()
  self._exitOnCtrlC = opts.exitOnCtrlC ~= false
  self._onCursor = opts.onCursor
  self._onAltScreen = opts.onAltScreen
  self._onTitle = opts.onTitle
  self._onClipboardWrite = opts.onClipboardWrite
  self._onTick = opts.onTick

  self._host = terminalHost.createTerminalHost(opts.writeFn or function() end)
  self._host.setColorCapability(opts.color or "auto")
  -- `opts.hyperlinks == nil and "auto" or opts.hyperlinks`, not `opts.hyperlinks
  -- or "auto"`: the latter would silently turn an explicit `hyperlinks = false`
  -- into "auto" (Lua's `or` can't distinguish "absent" from "falsy"), which
  -- would make it impossible for a caller to force hyperlinks OFF.
  self._host.setHyperlinkCapability(opts.hyperlinks == nil and "auto" or opts.hyperlinks)
  self._columns = positiveInteger(opts.columns, 80)
  self._rows = positiveInteger(opts.rows, 24)
  self._host.setSize(self._columns, self._rows)
  self._root = self._host.getRoot()
  self._reconciler = reconcilerModule.Reconciler.new(self._host)

  self._getWindowSize, self._setWindowSize = hydronium.signal({
    columns = self._columns,
    rows = self._rows,
  })
  self._getActiveFocusId, self._setActiveFocusId = hydronium.signal(nil)
  self._getFocusEnabled, self._setFocusEnabled = hydronium.signal(true)
  self._getAltScreen, self._setAltScreenSignal = hydronium.signal(false)

  local function deferWrite(write)
    if scheduler.isRendering() then
      self._pendingWrites[#self._pendingWrites + 1] = write
    else
      write()
    end
  end

  local function setFocus(id)
    deferWrite(function() self._setActiveFocusId(id) end)
  end

  local function activeFocusIds()
    local ids = {}
    for _, entry in ipairs(self._focusEntries) do
      if entry.isActive ~= false then ids[#ids + 1] = entry.id end
    end
    return ids
  end

  local function focusByOffset(offset)
    local ids = activeFocusIds()
    if #ids == 0 then return end
    local current = self._getActiveFocusId()
    local currentIndex
    for i, id in ipairs(ids) do if id == current then currentIndex = i break end end
    local nextIndex = currentIndex and ((currentIndex - 1 + offset) % #ids) + 1
      or (offset > 0 and 1 or #ids)
    setFocus(ids[nextIndex])
  end

  local function setAltScreen(enabled)
    enabled = enabled and true or false
    if enabled == self._altScreen then return false end
    self._altScreen = enabled
    self._host.invalidate()
    deferWrite(function() self._setAltScreenSignal(enabled) end)
    if self._onAltScreen then self._onAltScreen(enabled) end
    return true
  end

  local context = {
    registerInputHandler = function(handler)
      self._nextHandlerId = self._nextHandlerId + 1
      local id = self._nextHandlerId
      self._handlers[id] = handler
      return function() self._handlers[id] = nil end
    end,
    registerPasteHandler = function(handler)
      self._nextPasteHandlerId = self._nextPasteHandlerId + 1
      local id = self._nextPasteHandlerId
      self._pasteHandlers[id] = handler
      return function() self._pasteHandlers[id] = nil end
    end,
    exit = function(reason)
      self._exited, self._exitReason = true, reason
    end,
    windowSize = self._getWindowSize,
    generateFocusId = function()
      self._nextFocusId = self._nextFocusId + 1
      return "focus-" .. self._nextFocusId
    end,
    registerFocusable = function(id, focusOpts)
      local entry = { id = id, isActive = focusOpts.isActive }
      self._focusEntries[#self._focusEntries + 1] = entry
      if focusOpts.autoFocus and self._getActiveFocusId() == nil then setFocus(id) end
      return function()
        removeIdentity(self._focusEntries, entry)
        if self._getActiveFocusId() == id then setFocus(nil) end
      end
    end,
    isFocused = function(id) return self._getActiveFocusId() == id end,
    getActiveId = self._getActiveFocusId,
    enableFocus = function() self._setFocusEnabled(true) end,
    disableFocus = function() self._setFocusEnabled(false) end,
    focusNext = function() focusByOffset(1) end,
    focusPrevious = function() focusByOffset(-1) end,
    focus = function(id)
      for _, entry in ipairs(self._focusEntries) do
        if entry.id == id then setFocus(id) return end
      end
    end,
    setCursorPosition = function(position)
      self._cursor = position and { x = position.x or 0, y = position.y or 0 } or nil
      -- Tells the terminal host whether the cursor is CURRENTLY meant to
      -- be visible, so its own paint()-time hide/show (see
      -- host/terminal.lua's "CURSOR HIDE/SHOW" comment) restores this same
      -- steady state afterward instead of unconditionally showing it --
      -- otherwise an app that just called setCursorPosition(nil) to hide
      -- the cursor would see it reappear the next time anything repaints.
      self._host.setCursorVisible(self._cursor ~= nil)
      if self._onCursor then self._onCursor(self._cursor) end
    end,
    -- Both of these are, like setCursorPosition above, raw side channels
    -- that bypass the character-grid diff/paint pipeline entirely -- there
    -- is no "title" or "clipboard" cell in host/terminal.lua's grid, so
    -- there is nothing here for host.flush() to do. `self._title`/
    -- `self._lastClipboardWrite` are tracked regardless of whether a
    -- caller supplied onTitle/onClipboardWrite, purely so a deterministic
    -- test (see tests/host/ink_session_spec.lua) can assert on them
    -- without wiring a real writeFn -- the same reason Session:cursor()
    -- exists alongside onCursor.
    setTerminalTitle = function(title)
      self._title = tostring(title or "")
      if self._onTitle then self._onTitle(self._title) end
    end,
    writeClipboard = function(text)
      self._lastClipboardWrite = tostring(text or "")
      if self._onClipboardWrite then self._onClipboardWrite(self._lastClipboardWrite) end
    end,
    registerTicker = function(ticker)
      self._tickers[#self._tickers + 1] = ticker
      return function() removeIdentity(self._tickers, ticker) end
    end,
    setAltScreen = setAltScreen,
    altScreen = self._getAltScreen,
  }

  if opts.altScreen then setAltScreen(true) end
  self._wrapped = hydronium.h(hooks.InkAppContext.Provider, { value = context }, element)
  self._reconciler:mount(self._wrapped, self._root)
  self:_flushPendingWrites()
  self._host.flush()
  return self
end

function Session:_assertOpen(method)
  if self._closed then error("hydronium_ink.session:" .. method .. ": session is closed", 3) end
end

function Session:_flushPendingWrites()
  while #self._pendingWrites > 0 do
    local writes = self._pendingWrites
    self._pendingWrites = {}
    for _, write in ipairs(writes) do write() end
  end
end

function Session:_flush()
  self._host.flush()
  self:_flushPendingWrites()
  self._host.flush()
end

--- Dispatches one parsed Ink key or paste event.
function Session:dispatch(event)
  self:_assertOpen("dispatch")
  if type(event) ~= "table" then error("hydronium_ink.session:dispatch: event must be a table", 2) end
  if event.type == "paste" then
    for _, handler in pairs(self._pasteHandlers) do handler(event.text or "") end
  else
    local key = event.key or {}
    if self._getFocusEnabled() and key.tab then
      if key.shift then
        local ids = {}
        for _, entry in ipairs(self._focusEntries) do if entry.isActive ~= false then ids[#ids + 1] = entry.id end end
        if #ids > 0 then
          local current, index = self._getActiveFocusId(), nil
          for i, id in ipairs(ids) do if id == current then index = i break end end
          setFocus(ids[index and ((index - 2) % #ids) + 1 or #ids])
        end
      else
        focusByOffset(1)
      end
    end
    for _, handler in pairs(self._handlers) do handler(event.input or "", key) end
    if self._exitOnCtrlC and event.input == "c" and key.ctrl then self._exited = true end
  end
  self:_flush()
  return self:frame()
end

--- Feeds raw terminal bytes through Ink's real key parser.
function Session:write(bytes)
  self:_assertOpen("write")
  for _, event in ipairs(self._parser:feed(tostring(bytes or ""))) do self:dispatch(event) end
  return self:frame()
end

--- Flushes a pending lone-Escape event after the parser timeout.
function Session:flushInput()
  self:_assertOpen("flushInput")
  local event = self._parser:flushTimedOut()
  if event then self:dispatch(event) end
  return self:frame()
end

function Session:paste(text)
  return self:dispatch({ type = "paste", text = tostring(text or "") })
end

function Session:resize(columns, rows)
  self:_assertOpen("resize")
  columns, rows = positiveInteger(columns), positiveInteger(rows)
  if not columns or not rows then error("hydronium_ink.session:resize: columns and rows must be positive integers", 2) end
  if columns ~= self._columns or rows ~= self._rows then
    self._columns, self._rows = columns, rows
    self._setWindowSize({ columns = columns, rows = rows })
    self._host.setSize(columns, rows)
    self._host.invalidate()
    self:_flush()
  end
  return self:frame()
end

function Session:setColorCapability(capability)
  self:_assertOpen("setColorCapability")
  self._host.setColorCapability(capability)
  self:_flush()
  return self:frame()
end

--- @param capability boolean|"auto" See hydronium_ink.host.terminal's
---   setHyperlinkCapability. Independent of setColorCapability -- see this
---   file's own `hyperlinks` SessionOption doc comment for why.
function Session:setHyperlinkCapability(capability)
  self:_assertOpen("setHyperlinkCapability")
  self._host.setHyperlinkCapability(capability)
  self:_flush()
  return self:frame()
end

--- Advances animations and development polling with a caller-owned clock.
---
--- The default is WALL-CLOCK time, via hydronium_ink.clock. It used to fall
--- back to `os.clock() * 1000`, which is CPU time consumed by this process --
--- and render.lua's loop calls `step()` with no argument, so that fallback was
--- the live path for every real app. That loop spends virtually all of its
--- time blocked in `select()` and burns almost no CPU, so `os.clock()` crawled
--- forward a millisecond or two per second of real time: a `useAnimation`
--- ticker asking for a 110ms interval advanced roughly once a minute. Measured
--- on a real pty, a spinner painted ONE frame in 20 seconds.
---
--- clock.lua exists precisely for this and already documents the trap in its
--- own header; keys.lua's ESC timeout was moved across to it. This call site
--- was the one left behind.
function Session:step(nowMs)
  self:_assertOpen("step")
  nowMs = tonumber(nowMs) or clock.nowMs()
  for _, ticker in ipairs(self._tickers) do
    if ticker.isActive then ticker.tick(nowMs) end
  end
  if self._onTick then self._onTick(nowMs) end
  self:_flush()
  return self:frame()
end

function Session:frame()
  self:_assertOpen("frame")
  return self._host.getLastFrame()
end

function Session:cursor()
  self:_assertOpen("cursor")
  return self._cursor and { x = self._cursor.x, y = self._cursor.y } or nil
end

--- The current terminal title (empty string if never set), tracked
--- regardless of whether opts.onTitle was supplied -- see
--- context.setTerminalTitle's own doc comment.
--- @return string
function Session:title()
  self:_assertOpen("title")
  return self._title
end

--- The text most recently sent through `useClipboard().write(...)`, or
--- nil if never called -- tracked regardless of whether
--- opts.onClipboardWrite was supplied. There is no `lastClipboardRead`:
--- see this package's render.lua for why OSC 52 read isn't implemented.
--- @return string|nil
function Session:lastClipboardWrite()
  self:_assertOpen("lastClipboardWrite")
  return self._lastClipboardWrite
end

function Session:colorCapability()
  self:_assertOpen("colorCapability")
  return self._host._colorCapability
end

function Session:hyperlinkCapability()
  self:_assertOpen("hyperlinkCapability")
  return self._host._hyperlinkCapability
end

function Session:setAltScreen(enabled)
  self:_assertOpen("setAltScreen")
  enabled = enabled and true or false
  if enabled == self._altScreen then return false end
  self._altScreen = enabled
  self._setAltScreenSignal(enabled)
  self._host.invalidate()
  if self._onAltScreen then self._onAltScreen(enabled) end
  self:_flush()
  return true
end

function Session:status()
  return { exited = self._exited, exitReason = self._exitReason, closed = self._closed }
end

function Session:close()
  if self._closed then return end
  self._reconciler:unmount(self._wrapped)
  self._host.flush()
  self._closed = true
end

M.Session = Session
return M
