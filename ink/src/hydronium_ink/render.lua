-- Native blocking TTY adapter over hydronium_ink.session. The session owns
-- application semantics; this module owns POSIX terminal effects and waiting.
local ffi = require("ffi")
local sessionModule = require("hydronium_ink.session")

-- Wall-clock + in-process sleep. Loaded defensively: hydronium_ink.clock is
-- POSIX-only and raises on Windows, and the non-interactive render path below
-- is the one context that previously had no FFI dependency at all.
local clockOk, clockModule = pcall(require, "hydronium_ink.clock")
local sleepMs = clockOk and clockModule.sleepMs or nil

ffi.cdef([[int isatty(int fd);]])

local M = {}
local POLL_INTERVAL_MS = 33

--[[
  OSC (Operating System Command) SUPPORT -- EVALUATION AND SCOPE.

  This module owns every ANSI/OSC escape sequence this package ever
  writes (see this file's own top doc comment). OSC 8 hyperlinks are the
  mandatory one (see hydronium_ink.host.terminal's own "OSC 8 HYPERLINK
  GRID REPRESENTATION"/"Hyperlink capability" sections -- that one is
  per-cell/per-run, painted through the diffed character grid, so it
  lives there, not here). Everything below this comment is the other OSC
  families considered for this package, evaluated on whether they
  genuinely fit a component model (a tree of declarative elements +
  reactive hooks) rather than "can be bolted on":

  IMPLEMENTED here (whole-terminal, one-shot side channels -- the same
  category useCursor's setCursorPosition and useAltScreen's enter/leave
  already are: state that isn't a grid cell, written directly via
  writeFn, bypassing host/terminal.lua's diff entirely):
  - OSC 0/1/2 (window/icon title) -- `hooks.useTerminalTitle()`. Genuinely
    useful for exactly this package's stated build-UI use case ("Building
    my-project -- step 3/5" in the tab/window title while the live frame
    below shows the details). Universally supported by every VT100-
    descended terminal; no known semantic collisions with anything else.
  - OSC 52 clipboard **write only** -- `hooks.useClipboard()`, exposing
    `write(text)` but no `read()`. See that hook's own doc comment in
    hooks.lua for why read is skipped: it needs a round-trip (query the
    terminal, then parse its OSC 52 response back out of stdin), and
    keys.lua's parser has no concept of an OSC response at all today --
    that is a real protocol addition, not a small one, and most terminals
    disable OSC 52 *read* by default for the obvious security reason
    (silent clipboard exfiltration), so it would not reliably work even
    after being built. Write is one-way and universally low-risk by
    comparison (kitty, iTerm2, WezTerm, Windows Terminal, and tmux's own
    passthrough all support it).

  EVALUATED AND SKIPPED (documented here, not implemented):
  - OSC 9 / OSC 777 (desktop notifications, iTerm2 / rxvt-unicode
    conventions respectively): skipped. Three problems, not one: (1) no
    single agreed-upon convention -- iTerm2's OSC 9 takes a bare message,
    rxvt/urxvt's OSC 777 takes `notify;title;body`, and they are NOT
    interchangeable; (2) a real semantic collision -- ConEmu/Windows
    Terminal already use OSC 9 (specifically `9;4;...`) for TASKBAR
    PROGRESS, not a notification, so blindly emitting bare OSC 9 risks
    driving an unrelated UI element on some real, popular terminals; (3)
    this is a fire-and-forget side effect with no visual representation
    in this package's own render tree at all -- exactly the shape of
    thing this package's own mission brief already rejected once for
    spinners ("something users implement themselves"): an app that wants
    a desktop notification on a real OS is generally better served
    shelling out to a native notifier (terminal-notifier, notify-send,
    osascript) than trusting an inconsistent in-band escape code.
  - OSC 4 / 10 / 11 (palette entry / default-foreground / default-
    background): skipped in BOTH directions. SET mutates the user's
    actual terminal color scheme as a global, persistent side effect with
    no relation to this package's own render lifecycle or its careful
    alt-screen enter/leave teardown (see useAltScreen's own doc comment)
    -- there is no "undo" for having repainted someone's terminal palette
    out from under them, and it can outlive the process or bleed into
    other panes of a multiplexer. That is a bad fit for a UI library
    whose entire model is "own your own frame, leave everything else
    alone." QUERY (reading the terminal's own reported theme, e.g. for
    light/dark auto-detection) is genuinely useful in the abstract, but
    needs the exact same OSC-response round-trip infrastructure the
    skipped OSC 52 read above does, which does not exist in this
    package yet -- if that round-trip parsing is ever built for one of
    these, it is the more likely candidate to revisit, not OSC 4/10/11
    SET.
--]]

local BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Minimal RFC 4648 base64 encoder. OSC 52 (clipboard write, see this
--- file's own OSC evaluation comment above) requires its payload to be
--- base64-encoded, and this repo has no existing base64 utility anywhere
--- else to reuse (checked: no hits for "base64" outside vendored/build
--- output directories).
--- @param data string
--- @return string
local function base64Encode(data)
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local b1, b2, b3 = data:byte(i), data:byte(i + 1), data:byte(i + 2)
    local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
    out[#out + 1] = BASE64_CHARS:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = BASE64_CHARS:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    out[#out + 1] = b2 and BASE64_CHARS:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
    out[#out + 1] = b3 and BASE64_CHARS:sub(n % 64 + 1, n % 64 + 1) or "="
    i = i + 3
  end
  return table.concat(out)
end

--- @class hydronium_ink.RenderOptions
--- @field exitOnCtrlC? boolean
--- @field writeFn? fun(bytes: string)
--- @field onTick? fun(nowMs: number)
--- @field altScreen? boolean
--- @field color? "auto"|"ansi16"|"ansi256"|"truecolor"
--- @field hyperlinks? boolean|"auto" See hydronium_ink.session.SessionOptions.

--- Runs an Ink application until `useApp().exit()` or Ctrl+C. Lab and tests
--- should use `hydronium_ink.session` directly instead of entering this loop.
function M.render(element, opts)
  opts = opts or {}
  local interactive = ffi.C.isatty(0) == 1
  local tty = interactive and require("hydronium_ink.tty_ffi") or nil
  local writeFn = opts.writeFn
  if not writeFn then
    if interactive then
      writeFn = function(bytes) tty.writeAll(1, bytes) end
    else
      writeFn = io.write
    end
  end

  local size = { columns = 80, rows = 24 }
  if interactive then
    local measuredOk, measured = pcall(tty.getWindowSize)
    if measuredOk and measured.columns > 0 and measured.rows > 0 then size = measured end
  end

  local function writeCursor(position)
    if position == nil then
      writeFn("\27[?25l")
    else
      writeFn("\27[" .. ((position.y or 0) + 1) .. ";" .. ((position.x or 0) + 1) .. "H\27[?25h")
    end
  end

  -- OSC 0 sets BOTH the window title and the icon title in one write --
  -- covers OSC 0/1/2 without needing separate calls for OSC 1 (icon-only)
  -- / OSC 2 (window-only). Terminated with BEL (not ST) for the widest
  -- compatibility with older VT100-descended terminals, several of which
  -- only ever learned BEL as a title terminator. ESC/BEL are stripped
  -- from the title text itself so a caller-supplied string can never
  -- inject its own sequence terminator and smuggle extra escape bytes in.
  local function writeTitle(title)
    local safe = tostring(title or ""):gsub("[\27\7]", "")
    writeFn("\27]0;" .. safe .. "\7")
  end

  -- OSC 52 clipboard WRITE only (see this file's own OSC evaluation
  -- comment above for why read is not implemented). "c" selects the
  -- system clipboard buffer (as opposed to "p", the X11 primary
  -- selection) -- the one every non-X11 terminal (macOS Terminal/iTerm2,
  -- Windows Terminal, ...) actually honors.
  local function writeClipboard(text)
    writeFn("\27]52;c;" .. base64Encode(tostring(text or "")) .. "\27\\")
  end

  local app
  local savedTermios
  local altScreenActive = false
  local ok, err = pcall(function()
    if interactive then
      savedTermios = tty.enableRawMode()
      tty.setNonBlocking(0)
      writeFn("\27[?2004h")
      -- Kitty keyboard protocol, "disambiguate escape codes" (flag 1), pushed
      -- onto the terminal's own stack so the matching pop below restores
      -- whatever was set before rather than assuming it was off.
      --
      -- Flag 1 deliberately, not "report all keys": it leaves ordinary typing
      -- arriving as plain bytes and only escapes the keys that are otherwise
      -- AMBIGUOUS -- which is exactly the set that matters here. Without it a
      -- terminal cannot tell this app that Shift or Super were held for
      -- anything but Shift+Tab, so text-field selection and word motion are
      -- not expressible. Terminals that do not implement it ignore an
      -- unknown CSI, and the pop is equally harmless.
      writeFn("\27[>1u")
    end

    app = sessionModule.create(element, {
      columns = size.columns,
      rows = size.rows,
      color = opts.color,
      hyperlinks = opts.hyperlinks,
      exitOnCtrlC = opts.exitOnCtrlC,
      writeFn = writeFn,
      altScreen = opts.altScreen,
      onCursor = writeCursor,
      onAltScreen = function(enabled)
        altScreenActive = enabled
        writeFn(enabled and "\27[?1049h" or "\27[?1049l")
      end,
      onTitle = writeTitle,
      onClipboardWrite = writeClipboard,
      onTick = opts.onTick,
    })

    while not app:status().exited do
      if interactive then
        if tty.pollReadable(0, POLL_INTERVAL_MS) then
          local data = tty.readAvailable(0, 4096)
          if data then app:write(data) end
        end
        app:flushInput()

        local sizeOk, nextSize = pcall(tty.getWindowSize)
        if sizeOk and (nextSize.columns ~= size.columns or nextSize.rows ~= size.rows) then
          size = nextSize
          app:resize(size.columns, size.rows)
        end
      else
        -- Non-interactive pacing (piped stdout, CI). nanosleep, not
        -- `os.execute("sleep ...")`: that forked a shell and a `sleep` binary
        -- ~30 times a second for the whole run. See clock.sleepMs.
        --
        -- pcall-guarded so this path keeps working where the FFI clock cannot
        -- load (it is POSIX-only by its own doc comment) -- the shell fallback
        -- is slow, but it is better than failing to render at all.
        if sleepMs then
          sleepMs(POLL_INTERVAL_MS)
        else
          os.execute("sleep 0." .. string.format("%03d", POLL_INTERVAL_MS))
        end
      end
      app:step()
    end
  end)

  local exitReason = app and app:status().exitReason or nil
  if app then
    if altScreenActive then app:setAltScreen(false) end
    app:close()
  elseif altScreenActive then
    writeFn("\27[?1049l")
  end
  if interactive then
    -- Pop the keyboard-protocol flags first, then bracketed paste: reverse
    -- order of the pushes above, so a terminal that tracks these as a stack
    -- ends where it started.
    writeFn("\27[<u")
    writeFn("\27[?2004l")
  end
  if interactive and savedTermios then tty.restoreMode(savedTermios) end
  if not ok then error(err, 0) end
  return { exitReason = exitReason }
end

return M
