--[[
  hydronium_ink.hooks -- useInput/useApp/useWindowSize, built entirely on
  Hydronium's own EXISTING reactive primitives
  (createContext/useContext/onCleanup/createSignal, all in
  core/src/hydronium/{core/context.lua,core/scope.lua,signals/signal.lua})
  -- no new core framework feature was needed for this, exactly like real
  Ink's own hooks are ordinary React hooks built over useContext/useEffect.

  render.lua provides `InkAppContext`'s value at the root
  (`hydronium.h(hooks.InkAppContext.Provider, { value = ... }, app)`);
  every hook here just reads it via `useContext` and fails loudly if
  called outside that provider (i.e. outside a tree mounted via
  `ink.render()`).

  KNOWN SIMPLIFICATION, stated plainly (see docs/... once this lands):
  Hydronium's component model is "setup once, render many" (see
  core/component.lua's ComponentInstance:render() -- the outer function
  call happens exactly once; if it returns a function, THAT is what runs
  on every subsequent render). Hooks here are only meant to be called
  during that one-time setup call (exactly how this repo's own existing
  demo already writes components -- `function App() return function()
  ... end end`), not from inside the returned per-render closure. Real
  Ink's `useInput(handler, { isActive })` re-registers/deregisters
  reactively whenever `isActive` changes across renders (a real
  `useEffect` dependency-array rerun); this module's `useInput` reads
  `opts.isActive` ONCE, at the one-time setup call, not reactively --
  toggling behavior dynamically needs an `if` inside the handler itself
  for now. Not attempted here: full dependency-driven hook re-run
  semantics matching React's.
--]]

local hydronium = require("hydronium")

local M = {}

--- The context render.lua provides at the root of every `ink.render()`
--- tree. Not meant to be constructed or provided by anything else.
M.InkAppContext = hydronium.createContext(nil)

--- @class hydronium_ink.InkAppContextValue
--- @field registerInputHandler fun(handler: fun(input: string, key: hydronium_ink.Key)): fun() Returns an unregister function.
--- @field exit fun(err: any?)
--- @field windowSize fun(): hydronium_ink.WindowSize A reactive signal getter (see hydronium_ink.tty_ffi.WindowSize).
--- @field registerFocusable fun(id: string, opts: { autoFocus: boolean, isActive: boolean }): fun() Returns an unregister function.
--- @field generateFocusId fun(): string
--- @field isFocused fun(id: string): boolean
--- @field getActiveId fun(): string|nil A reactive signal getter.
--- @field enableFocus fun()
--- @field disableFocus fun()
--- @field focusNext fun()
--- @field focusPrevious fun()
--- @field focus fun(id: string)
--- @field setCursorPosition fun(position: { x: number, y: number }|nil)
--- @field registerTicker fun(ticker: { tick: fun(nowMs: number), isActive: boolean }): fun() Returns an unregister function.
--- @field registerPasteHandler fun(handler: fun(text: string)): fun() Returns an unregister function.
--- @field setAltScreen fun(enabled: boolean): boolean Switches the terminal's alternate screen buffer on/off. Returns whether this call changed anything.
--- @field altScreen fun(): boolean A reactive signal getter.
--- @field setTerminalTitle fun(title: string) Sets the terminal window/icon title (OSC 0).
--- @field writeClipboard fun(text: string) Writes to the system clipboard (OSC 52, write-only -- see render.lua's OSC evaluation comment for why there is no read).

--- @return hydronium_ink.InkAppContextValue
local function requireAppContext(hookName)
  local ctx = hydronium.useContext(M.InkAppContext)
  if not ctx then
    error(
      "hydronium_ink.hooks." .. hookName .. ": no Ink app context found -- "
        .. hookName .. " must be called from a component rendered under ink.render()",
      3
    )
  end
  return ctx
end

--- @class hydronium_ink.UseInputOptions
--- @field isActive? boolean Default true. Read once at setup (see this module's own doc comment for why this isn't reactive yet).

--- Registers `handler(input, key)` to be called for every real keypress
--- while this component is mounted (and `isActive` was true at setup
--- time). Unregistered automatically on unmount via `hydronium.onCleanup`
--- -- see core/scope.lua's onCleanup/Scope:defer, the same mechanism
--- createEffect already relies on for its own cleanup.
--- @param handler fun(input: string, key: hydronium_ink.Key)
--- @param opts? hydronium_ink.UseInputOptions
function M.useInput(handler, opts)
  opts = opts or {}
  local isActive = opts.isActive
  if isActive == nil then
    isActive = true
  end
  if not isActive then
    return
  end

  local ctx = requireAppContext("useInput")
  local unregister = ctx.registerInputHandler(handler)
  hydronium.onCleanup(unregister)
end

--- @class hydronium_ink.UsePasteOptions
--- @field isActive? boolean Default true. Read once at setup (see this module's own doc comment for why this isn't reactive yet) -- matches real Ink's own documented purpose: "useful when multiple components use usePaste."

--- Registers `handler(text)` to be called with the verbatim pasted text
--- (newlines and other special characters preserved exactly, matching
--- real Ink's own documented behavior) whenever a real bracketed paste
--- (`ESC[200~...ESC[201~`, see keys.lua) is detected while this component
--- is mounted. Dispatched separately from `useInput`'s handlers -- a
--- paste never also fires as a stream of individual key events. Renders
--- render.lua's own DECSET 2004 setup/teardown moot if this is never
--- called at all in a given app: enabling the terminal mode has no
--- effect on anything `useInput` sees either way.
--- @param handler fun(text: string)
--- @param opts? hydronium_ink.UsePasteOptions
function M.usePaste(handler, opts)
  opts = opts or {}
  local isActive = opts.isActive
  if isActive == nil then
    isActive = true
  end
  if not isActive then
    return
  end

  local ctx = requireAppContext("usePaste")
  local unregister = ctx.registerPasteHandler(handler)
  hydronium.onCleanup(unregister)
end

--- @class hydronium_ink.UseAppResult
--- @field exit fun(err: any?) Ends render()'s event loop. `err`, if given, becomes render()'s own return value (see render.lua).

--- @return hydronium_ink.UseAppResult
function M.useApp()
  local ctx = requireAppContext("useApp")
  return { exit = ctx.exit }
end

--- Reactive: reading `.columns`/`.rows` from this call's result during a
--- tracked render (either the one-time setup call or the returned
--- per-render closure -- see this module's doc comment) subscribes that
--- render to the underlying signal exactly like reading any other
--- Hydronium signal does, via the same automatic dependency tracking
--- `createSignal`'s getter already provides -- no extra wiring needed
--- here beyond calling the getter render.lua installed on the context.
--- @return hydronium_ink.WindowSize
function M.useWindowSize()
  local ctx = requireAppContext("useWindowSize")
  return ctx.windowSize()
end

--- @class hydronium_ink.UseFocusOptions
--- @field autoFocus? boolean Default false. Claims the active focus slot at registration time, but only if nothing else already holds it.
--- @field isActive? boolean Default true. Keeps this component's slot/position in the focus cycle either way; when false, Tab/Shift+Tab and autoFocus skip it. Read once at setup, not reactively -- same stated simplification as useInput's own opts.isActive above.
--- @field id? string Explicit focus id, usable with `useFocusManager().focus(id)`. Auto-generated (e.g. "focus-1") if omitted.

--- @class hydronium_ink.UseFocusResult
--- @field isFocused fun(): boolean A REACTIVE GETTER, not a plain boolean like real Ink's own `useFocus` returns -- Hydronium's setup-once component model (see this module's own top doc comment) means a plain value captured at this call would never update. Call it from your component's render closure (the function your setup call returns), the same pattern useWindowSize()/useBoxMetrics() already establish, to get the current value on every render.

--- Registers this component as one node in the app-wide focus cycle that
--- Tab/Shift+Tab navigate (see keys.lua's `ESC[Z` handling and
--- render.lua's dispatchEvent wiring). Must be called once at a
--- component's one-time setup call, like useInput/useApp above -- NOT
--- from inside the returned per-render closure -- since it registers a
--- real `hydronium.onCleanup` for unmount.
--- @param opts? hydronium_ink.UseFocusOptions
--- @return hydronium_ink.UseFocusResult
function M.useFocus(opts)
  opts = opts or {}
  local ctx = requireAppContext("useFocus")
  local id = opts.id or ctx.generateFocusId()
  local isActive = opts.isActive
  if isActive == nil then
    isActive = true
  end

  local unregister = ctx.registerFocusable(id, { autoFocus = opts.autoFocus or false, isActive = isActive })
  hydronium.onCleanup(unregister)

  return {
    isFocused = function()
      return ctx.isFocused(id)
    end,
  }
end

--- @class hydronium_ink.UseFocusManagerResult
--- @field enableFocus fun() Enable focus management (Tab/Shift+Tab navigation) for all components. Enabled by default.
--- @field disableFocus fun()
--- @field focusNext fun()
--- @field focusPrevious fun()
--- @field focus fun(id: string) No-op if no registered component has that id (matches real Ink's own documented behavior).
--- @field activeId string|nil The currently focused component's id, or nil. Read ONCE at this call, not a reactively-updating field the way real Ink's own hook re-returns it every render -- call `useFocusManager()` again from your render closure for an updated value (same pattern as `useFocus`'s `isFocused` above and useWindowSize()/useBoxMetrics()).

--- @return hydronium_ink.UseFocusManagerResult
function M.useFocusManager()
  local ctx = requireAppContext("useFocusManager")
  return {
    enableFocus = ctx.enableFocus,
    disableFocus = ctx.disableFocus,
    focusNext = ctx.focusNext,
    focusPrevious = ctx.focusPrevious,
    focus = ctx.focus,
    activeId = ctx.getActiveId(),
  }
end

--- @class hydronium_ink.UseCursorResult
--- @field setCursorPosition fun(position: { x: number, y: number }|nil) `position` is 0-based and relative to Ink's own rendered output (`x` = column, `y` = row, `y = 0` is the first line) -- matching real Ink's own documented shape. Pass `nil` to hide the cursor. Writes a real cursor-move+show (or hide) ANSI escape sequence directly, bypassing the terminal host's own diff/paint pipeline entirely (there is no "cursor" in the character grid it paints). STATED LIMITATION: every repaint that actually changes something re-parks the cursor below the frame (see host/terminal.lua's own paint() comment on why) -- a persistent custom position needs re-calling this after each of your own updates that might trigger one, same as a real terminal text-input implementation has to. Every changed repaint ALSO transiently hides the cursor for the duration of its own write (flicker fix -- see host/terminal.lua's "CURSOR HIDE/SHOW" comment) and restores it to whatever visibility YOU last set here, not unconditionally visible -- calling `setCursorPosition(nil)` still keeps the cursor hidden across subsequent repaints, it does not get silently re-shown.

--- @return hydronium_ink.UseCursorResult
function M.useCursor()
  local ctx = requireAppContext("useCursor")
  return {
    setCursorPosition = ctx.setCursorPosition,
  }
end

--- @class hydronium_ink.UseAltScreenResult
--- @field enter fun(): boolean Switch into the terminal's alternate screen buffer. Returns true if this call actually switched (false if already there).
--- @field leave fun(): boolean Switch back to the normal screen.
--- @field toggle fun(): boolean Leave if currently in the alternate screen, enter otherwise.
--- @field isActive fun(): boolean REACTIVE GETTER (not a plain boolean -- see this module's own "setup once" doc comment, same deviation as useFocus's isFocused above). Read it from your render closure to render a different view per screen.

--- The terminal's ALTERNATE SCREEN BUFFER (DECSET 1049) -- what a
--- fullscreen TUI (vim, less, htop) runs in, so that leaving it restores
--- the shell's real scrollback instead of leaving a painted frame behind.
--- render.lua owns the escape sequences, the repaint invalidation each
--- switch needs, and -- importantly -- leaving the alternate screen when
--- render() returns for ANY reason, including a component error or Ctrl+C
--- (see its `altScreen` option and teardown). Safe to call from a
--- component's one-time setup call as well as from an input handler.
---
--- Unlike every other hook here this registers nothing and has no cleanup:
--- it is a pair of functions over one process-wide terminal mode, so a
--- component that enters the alternate screen and then unmounts does NOT
--- implicitly leave it -- whoever entered decides when to leave (or lets
--- render()'s own teardown do it).
--- @return hydronium_ink.UseAltScreenResult
function M.useAltScreen()
  local ctx = requireAppContext("useAltScreen")
  return {
    enter = function()
      return ctx.setAltScreen(true)
    end,
    leave = function()
      return ctx.setAltScreen(false)
    end,
    toggle = function()
      return ctx.setAltScreen(not ctx.altScreen())
    end,
    isActive = ctx.altScreen,
  }
end

--- @class hydronium_ink.UseTerminalTitleResult
--- @field setTitle fun(title: string) Sets the terminal's window/icon title (OSC 0, which covers both the window and icon title in one write -- see render.lua's own OSC evaluation comment for why OSC 1/2 don't need separate calls). Writes a real escape sequence directly, bypassing the character-grid diff/paint pipeline entirely -- same rationale as useCursor's setCursorPosition above (there is no "title" cell in the grid host/terminal.lua paints). Pass an empty string to clear it. Fire-and-forget, like useAltScreen's enter/leave: no reactive getter, since nothing here ever reads a title back FROM the terminal (there is no portable query for it).

--- The terminal's window/icon title. Genuinely useful for this package's
--- own stated build-UI use case (showing overall progress in the tab/
--- window title while the live frame below shows step detail), and safe
--- to call from a component's one-time setup call, its render closure, or
--- an input/tick handler alike -- unlike useFocus/useInput/useAnimation
--- above, this registers nothing and needs no cleanup, so there is no
--- "must be called once at setup" restriction here.
--- @return hydronium_ink.UseTerminalTitleResult
function M.useTerminalTitle()
  local ctx = requireAppContext("useTerminalTitle")
  return {
    setTitle = ctx.setTerminalTitle,
  }
end

--- @class hydronium_ink.UseClipboardResult
--- @field write fun(text: string) Writes `text` to the system clipboard via OSC 52 (terminals that don't support it silently ignore an unrecognized OSC, same as any other unknown escape -- there is no plain-text degradation path needed the way OSC 8 hyperlinks have one, since a clipboard write has no visible on-screen representation to fall back to).

--- Clipboard WRITE only -- see render.lua's own top-of-file OSC evaluation
--- comment for why `read()` is not implemented (it needs a round-trip
--- through keys.lua's input parser that does not exist yet, and most
--- terminals disable OSC 52 read by default for security regardless).
--- @return hydronium_ink.UseClipboardResult
function M.useClipboard()
  local ctx = requireAppContext("useClipboard")
  return {
    write = ctx.writeClipboard,
  }
end

--- @class hydronium_ink.UseAnimationOptions
--- @field interval? number Default 100 (ms) between ticks, matching real Ink's own default.
--- @field isActive? boolean Default true. Read once at setup, not reactively -- same stated simplification as useInput's own opts.isActive above; toggling dynamically needs `reset()` plus re-registering (i.e. remounting the component), not a live prop flip.

--- @class hydronium_ink.UseAnimationResult
--- @field frame fun(): integer REACTIVE GETTER (not a plain number -- see this module's own "setup once" doc comment, same deviation as useFocus's isFocused/useFocusManager's activeId above). Discrete counter, +1 per elapsed interval.
--- @field time fun(): number REACTIVE GETTER. Total elapsed ms since start or the last reset().
--- @field delta fun(): number REACTIVE GETTER. Ms since the previous tick (render.lua's loop only checks tickers once per ~33ms poll iteration -- see POLL_INTERVAL_MS -- so `delta` reflects real elapsed time, not exactly `interval`, matching real Ink's own "accounts for throttled renders" documented behavior).
--- @field reset fun() Zeroes frame/time/delta and restarts timing from now.

--- Registers a real timer ticker with render.lua's event loop (checked once
--- per loop iteration against WALL-CLOCK time from hydronium_ink.clock, the
--- same source keys.lua's ESC-alone timeout uses).
---
--- This comment used to say `os.clock() * 1000`, and so did Session:step's
--- default -- which is CPU time, not wall time. A loop that sits in select()
--- burns almost no CPU: measured across a real 2013 ms wait, os.clock()
--- advanced 0.37 ms, i.e. 0.0002x real time, which turns a 110 ms interval
--- into one tick per ~600 seconds. Must be called once at a
--- component's one-time setup call, like useInput/useFocus above -- NOT
--- from inside the returned per-render closure -- since it registers a
--- real `hydronium.onCleanup` for unmount.
--- @param opts? hydronium_ink.UseAnimationOptions
--- @return hydronium_ink.UseAnimationResult
function M.useAnimation(opts)
  opts = opts or {}
  local interval = opts.interval or 100
  local isActive = opts.isActive
  if isActive == nil then
    isActive = true
  end

  local ctx = requireAppContext("useAnimation")

  local getFrame, setFrame = hydronium.signal(0)
  local getTime, setTime = hydronium.signal(0)
  local getDelta, setDelta = hydronium.signal(0)

  local startedAtMs, lastTickAtMs = nil, nil

  local function reset()
    startedAtMs, lastTickAtMs = nil, nil
    setFrame(0)
    setTime(0)
    setDelta(0)
  end

  local ticker = {
    isActive = isActive,
    tick = function(nowMs)
      if startedAtMs == nil then
        startedAtMs, lastTickAtMs = nowMs, nowMs
        return
      end
      if nowMs - lastTickAtMs >= interval then
        local delta = nowMs - lastTickAtMs
        lastTickAtMs = nowMs
        setFrame(getFrame() + 1)
        setTime(nowMs - startedAtMs)
        setDelta(delta)
      end
    end,
  }

  local unregister = ctx.registerTicker(ticker)
  hydronium.onCleanup(unregister)

  return {
    frame = getFrame,
    time = getTime,
    delta = getDelta,
    reset = reset,
  }
end

--- Thin wrapper over `hydronium_ink.measure.measureElement(ref)`,
--- matching real Ink's own `useBoxMetrics` hook name/shape.
--- KNOWN SIMPLIFICATION: unlike `useWindowSize()` above, this is NOT
--- backed by a reactive signal -- there is no push notification when an
--- element's layout changes, only whatever `ref.current._layout` holds
--- at the moment this is called. Calling it from a component's
--- per-render closure (not just its one-time setup) means it reflects
--- the latest measured layout on every render that closure already
--- runs for some OTHER reactive reason -- it does not, by itself, cause
--- a re-render when layout changes with nothing else driving one.
--- Does NOT require an Ink app context (`ink.render()`) -- reading a
--- ref's own measured layout has no dependency on it, unlike every
--- other hook in this file.
--- @param ref table A `hydronium.createRef()` bound via a `ref` prop.
--- @return hydronium_ink.ElementMetrics
function M.useBoxMetrics(ref)
  return require("hydronium_ink.measure").measureElement(ref)
end

return M
