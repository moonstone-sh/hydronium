--[[
  hydronium_ink.render -- the real entry point an app actually calls
  (`ink.render(App())`), replacing the demo's own hand-assembled
  host/reconciler/mount/flush wiring with something that also does raw
  mode, real keyboard input, and resize detection.

  EVENT MODEL, stated plainly (see docs/... once this lands): LuaJIT has
  no real async runtime. Rather than build a non-blocking render() that
  returns immediately -- which would need coroutines threaded through
  the whole reconciler/host to be honest, not just bolted on here --
  render() runs a real BLOCKING event loop until exit() is called or
  Ctrl+C fires (unless opts.exitOnCtrlC is explicitly false), and
  returns only once that loop ends. This matches how this module's own
  existing demo (examples/ink_demo/run.lua) already works -- a blocking
  tick loop -- just with real input/resize driving it instead of a fixed
  os.execute("sleep 0.3").

  Each loop iteration:
    1. Poll stdin for readability (hydronium_ink.tty_ffi.pollReadable,
       bounded wait so resize/flush below still run even with no input).
    2. If readable: non-blocking read, feed through the key parser
       (hydronium_ink.keys), dispatch every produced event to every
       currently-registered useInput handler.
    3. Check the key parser's own ESC-alone timeout
       (Parser:flushTimedOut) even when nothing new arrived this
       iteration -- a lone Escape keypress needs real wall-clock time to
       pass before it can be told apart from the start of a longer
       sequence (see keys.lua's own doc comment).
    4. Poll the real terminal size (tty_ffi.getWindowSize); if it
       changed since the last iteration, update the reactive window-size
       signal exposed to useWindowSize().
    5. host.flush() (a no-op if nothing is actually dirty).
    6. If exit() was called (by useApp() or the default Ctrl+C handler),
       fall out of the loop.

  PLATFORM SCOPE: raw mode (tty_ffi) is POSIX-only. If stdin isn't a
  real TTY (piped input, non-interactive CI, etc.) or this is Windows,
  render() still mounts and paints once, but skips raw mode and the
  input-reading part of the loop entirely -- there is nothing to read
  keys from in that case, and forcing termios calls against a non-tty
  fd would just fail loudly for no benefit. This is a real, deliberate
  degradation, not a silent limitation: `useInput` handlers simply never
  fire in that mode, `useApp().exit()` still works (a component can
  still choose to end the loop itself), and `useWindowSize()` returns
  whatever `tty_ffi.getWindowSize()` last successfully reported (or a
  zero size if it never could).
--]]

local ffi = require("ffi")
local hydronium = require("hydronium")
local reconcilerModule = require("hydronium.core.reconciler")
local terminalHostModule = require("hydronium_ink.host.terminal")
local hooks = require("hydronium_ink.hooks")
local keys = require("hydronium_ink.keys")

local M = {}

ffi.cdef([[int isatty(int fd);]])

-- One poll/paint cycle per iteration, at roughly this cadence -- matches
-- real Ink's own documented `maxFps: 30` default closely enough for a
-- terminal UI (33ms ~= 30fps) without busy-looping the CPU on every
-- iteration when no input is pending.
local POLL_INTERVAL_MS = 33

--- @class hydronium_ink.RenderOptions
--- @field exitOnCtrlC? boolean Default true, matching real Ink's own option name/default.
--- @field writeFn? fun(s: string) Byte-string sink, defaults to `io.write`. Passed straight through to the terminal host (see host/terminal.lua) AND reused for useCursor's own direct escape-sequence writes below, so both go through one real sink -- injectable for tests the same way host/terminal.lua's own `writeFn` already is.
--- @field onTick? fun() Called once per event-loop turn, before the host
---   flushes. Development tools can use this host-neutral seam to poll for
---   module updates; render itself does not know about files or compilers.

--- @class hydronium_ink.RenderResult
--- @field exitReason any Whatever `useApp().exit(err)` was called with, or `nil` for a normal exit.

--- @param element LuaxElement
--- @param opts? hydronium_ink.RenderOptions
--- @return hydronium_ink.RenderResult
function M.render(element, opts)
  opts = opts or {}
  local exitOnCtrlC = opts.exitOnCtrlC
  if exitOnCtrlC == nil then
    exitOnCtrlC = true
  end
  local writeFn = opts.writeFn or io.write

  local interactive = ffi.C.isatty(0) == 1

  local host = terminalHostModule.createTerminalHost(writeFn)
  local root = host.getRoot()
  local reconciler = reconcilerModule.Reconciler.new(host)

  local handlers = {}
  local nextHandlerId = 0

  local function registerInputHandler(handler)
    nextHandlerId = nextHandlerId + 1
    local id = nextHandlerId
    handlers[id] = handler
    return function()
      handlers[id] = nil
    end
  end

  local pasteHandlers = {}
  local nextPasteHandlerId = 0

  local function registerPasteHandler(handler)
    nextPasteHandlerId = nextPasteHandlerId + 1
    local id = nextPasteHandlerId
    pasteHandlers[id] = handler
    return function()
      pasteHandlers[id] = nil
    end
  end

  -- Focus registry (useFocus/useFocusManager, see hooks.lua). `entries`
  -- preserves registration order (Tab/Shift+Tab cycle through it in that
  -- order, matching real Ink); `isActive` is captured once at
  -- registration time, not reactively -- same stated simplification as
  -- useInput's own opts.isActive above.
  local focusEntries = {} -- array of { id, isActive }
  local getActiveFocusId, setActiveFocusId = hydronium.signal(nil)
  local getFocusEnabled, setFocusEnabled = hydronium.signal(true)
  local nextFocusId = 0

  -- Signal writes are rejected (ERR_RENDER_MUTATION, see
  -- core/signals/signal.lua) while a component's setup or render-closure
  -- call is on the stack -- and `useFocus`'s autoFocus registration (and
  -- an unmount's own unregister, which can itself fire mid-reconcile)
  -- both happen from exactly there. Route every focus-id write through
  -- this: run it immediately when that's safe, or queue it for
  -- `flushPendingFocusOps()` (called right after mount and after every
  -- loop iteration's `host.flush()`, both real outside-any-render
  -- points) when it isn't.
  local schedulerModule = require("hydronium.core.scheduler")
  local pendingFocusOps = {}

  local function safeSetActiveFocusId(id)
    if schedulerModule.isRendering() then
      table.insert(pendingFocusOps, function()
        setActiveFocusId(id)
      end)
    else
      setActiveFocusId(id)
    end
  end

  local function flushPendingFocusOps()
    if #pendingFocusOps == 0 then
      return
    end
    local ops = pendingFocusOps
    pendingFocusOps = {}
    for _, op in ipairs(ops) do
      op()
    end
  end

  local function generateFocusId()
    nextFocusId = nextFocusId + 1
    return "focus-" .. nextFocusId
  end

  local function findFocusEntryIndex(id)
    for i, entry in ipairs(focusEntries) do
      if entry.id == id then
        return i
      end
    end
    return nil
  end

  local function registerFocusable(id, opts)
    table.insert(focusEntries, { id = id, isActive = opts.isActive })
    if opts.autoFocus and getActiveFocusId() == nil then
      safeSetActiveFocusId(id)
    end
    return function()
      local idx = findFocusEntryIndex(id)
      if idx then
        table.remove(focusEntries, idx)
      end
      if getActiveFocusId() == id then
        safeSetActiveFocusId(nil)
      end
    end
  end

  local function focusByOffset(offset)
    local active = {}
    for _, entry in ipairs(focusEntries) do
      if entry.isActive ~= false then
        table.insert(active, entry.id)
      end
    end
    if #active == 0 then
      return
    end
    local currentIdx = nil
    for i, id in ipairs(active) do
      if id == getActiveFocusId() then
        currentIdx = i
        break
      end
    end
    local nextIdx
    if currentIdx == nil then
      nextIdx = offset > 0 and 1 or #active
    else
      nextIdx = ((currentIdx - 1 + offset) % #active) + 1
    end
    safeSetActiveFocusId(active[nextIdx])
  end

  local function focusNext()
    focusByOffset(1)
  end

  local function focusPrevious()
    focusByOffset(-1)
  end

  local function focusById(id)
    if findFocusEntryIndex(id) then
      safeSetActiveFocusId(id)
    end
  end

  local exited, exitReason = false, nil
  local function exit(err)
    exited = true
    exitReason = err
  end

  -- useAnimation tickers. Each entry is `{ tick = fun(nowMs), isActive =
  -- boolean }` -- `tick` (built in hooks.lua, holding its own signals
  -- closed over) is called once per loop iteration below (both the
  -- interactive and non-interactive branches -- an animation has no
  -- dependency on stdin) with the same clock source keys.lua's own
  -- ESC-alone timeout already uses (`os.clock() * 1000`), for
  -- consistency with that existing precedent rather than introducing a
  -- second clock source. `isActive` is read once at registration, same
  -- stated simplification as useInput's/useFocus's own opts.isActive.
  local tickers = {}

  local function registerTicker(ticker)
    table.insert(tickers, ticker)
    return function()
      for i, t in ipairs(tickers) do
        if t == ticker then
          table.remove(tickers, i)
          break
        end
      end
    end
  end

  -- useCursor: a real cursor-move+show (or hide) escape sequence written
  -- DIRECTLY via the same `writeFn` the host itself uses, bypassing the
  -- host's own diff/paint pipeline entirely -- there is no "cursor"
  -- concept in the cell grid host/terminal.lua paints, only characters.
  -- STATED LIMITATION: host.paint() unconditionally parks the cursor at
  -- row (h+1) after every repaint it actually writes (see that file's
  -- own comment on the line that does it) -- a persistent custom
  -- position needs re-calling setCursorPosition after each of your own
  -- updates that might trigger a repaint, exactly like a real Ink app
  -- driving cursor position for e.g. a text input has to.
  -- `position` matches real Ink's own documented shape: `{x, y}`,
  -- 0-based, relative to Ink's own output -- and since this host always
  -- paints its frame starting at the real terminal's row 1 (host.paint's
  -- own `\27[2J\27[H` / `\27[y;1H` sequences), "relative to Ink's
  -- output" and "absolute terminal position" are the same coordinate
  -- system here; y=0 is the frame's own first row.
  local function setCursorPosition(position)
    if position == nil then
      writeFn("\27[?25l")
    else
      local row, col = (position.y or 0) + 1, (position.x or 0) + 1
      writeFn("\27[" .. row .. ";" .. col .. "H\27[?25h")
    end
  end

  local ttyFfi = nil
  local initialSize = { columns = 0, rows = 0 }
  if interactive then
    -- Deferred require: only pulls in tty_ffi.lua (and therefore its
    -- POSIX-only ffi.cdef, see that module's own doc comment) when
    -- stdin is actually a real TTY -- a non-interactive run never even
    -- attempts the platform-specific struct layout, matching this
    -- module's own "no benefit to forcing it" scope note above.
    ttyFfi = require("hydronium_ink.tty_ffi")
    local ok, size = pcall(ttyFfi.getWindowSize)
    if ok then
      initialSize = size
    end
  end

  local getWindowSize, setWindowSize = hydronium.signal(initialSize)

  local appContextValue = {
    registerInputHandler = registerInputHandler,
    exit = exit,
    windowSize = getWindowSize,
    registerFocusable = registerFocusable,
    generateFocusId = generateFocusId,
    isFocused = function(id)
      return getActiveFocusId() == id
    end,
    getActiveId = getActiveFocusId,
    enableFocus = function()
      setFocusEnabled(true)
    end,
    disableFocus = function()
      setFocusEnabled(false)
    end,
    focusNext = focusNext,
    focusPrevious = focusPrevious,
    focus = focusById,
    setCursorPosition = setCursorPosition,
    registerTicker = registerTicker,
    registerPasteHandler = registerPasteHandler,
  }

  local wrapped = hydronium.h(hooks.InkAppContext.Provider, { value = appContextValue }, element)

  local savedTermios = nil
  local parser = interactive and keys.newParser() or nil

  local function dispatchEvent(event)
    if event.type == "paste" then
      for _, handler in pairs(pasteHandlers) do
        handler(event.text)
      end
      return
    end
    if getFocusEnabled() and event.key.tab then
      if event.key.shift then
        focusPrevious()
      else
        focusNext()
      end
    end
    for _, handler in pairs(handlers) do
      handler(event.input, event.key)
    end
    if exitOnCtrlC and event.input == "c" and event.key.ctrl then
      exit()
    end
  end

  -- Every step from here on runs inside one pcall so a component/handler
  -- error still restores the terminal before propagating -- see this
  -- module's own doc comment on the "explicit gap" this does NOT cover
  -- (an uncaught signal or a direct os.exit() call bypassing this
  -- function's own return path).
  local ok, err = pcall(function()
    if interactive then
      savedTermios = ttyFfi.enableRawMode()
      ttyFfi.setNonBlocking(0)
      -- DECSET 2004 -- see keys.lua's PASTE_START/PASTE_END doc comment
      -- for why this needs to be on at all: without it, a real terminal
      -- delivers pasted text as ordinary keystrokes indistinguishable
      -- from real typing, one byte/char at a time.
      writeFn("\27[?2004h")
    end

    reconciler:mount(wrapped, root)
    flushPendingFocusOps()
    host.flush()

    while not exited do
      if interactive then
        if ttyFfi.pollReadable(0, POLL_INTERVAL_MS) then
          local data = ttyFfi.readAvailable(0, 4096)
          if data then
            for _, event in ipairs(parser:feed(data)) do
              dispatchEvent(event)
            end
          end
        end
        local timedOut = parser:flushTimedOut()
        if timedOut then
          dispatchEvent(timedOut)
        end

        local sizeOk, size = pcall(ttyFfi.getWindowSize)
        if sizeOk then
          local current = getWindowSize()
          if size.columns ~= current.columns or size.rows ~= current.rows then
            setWindowSize(size)
          end
        end
      else
        -- No stdin to poll -- still pace the loop instead of spinning,
        -- since a non-interactive render() only ever ends via exit().
        os.execute("sleep 0." .. string.format("%03d", POLL_INTERVAL_MS))
      end

      if #tickers > 0 then
        -- Deferred require, same reasoning as tty_ffi.lua above: a
        -- render() that never uses useAnimation (or a Windows run that
        -- only ever hits the non-interactive path) never touches
        -- clock.lua's own POSIX-only ffi.cdef at all.
        local now = require("hydronium_ink.clock").nowMs()
        for _, ticker in ipairs(tickers) do
          if ticker.isActive then
            ticker.tick(now)
          end
        end
      end

      if opts.onTick then
        opts.onTick()
      end

      host.flush()
      flushPendingFocusOps()
    end
  end)

  if interactive then
    writeFn("\27[?2004l")
  end
  if interactive and savedTermios then
    ttyFfi.restoreMode(savedTermios)
  end

  if not ok then
    error(err, 0)
  end

  return { exitReason = exitReason }
end

return M
