-- Native blocking TTY adapter over hydronium_ink.session. The session owns
-- application semantics; this module owns POSIX terminal effects and waiting.
local ffi = require("ffi")
local sessionModule = require("hydronium_ink.session")

ffi.cdef([[int isatty(int fd);]])

local M = {}
local POLL_INTERVAL_MS = 33

--- @class hydronium_ink.RenderOptions
--- @field exitOnCtrlC? boolean
--- @field writeFn? fun(bytes: string)
--- @field onTick? fun(nowMs: number)
--- @field altScreen? boolean
--- @field color? "auto"|"ansi16"|"ansi256"|"truecolor"

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

  local app
  local savedTermios
  local altScreenActive = false
  local ok, err = pcall(function()
    if interactive then
      savedTermios = tty.enableRawMode()
      tty.setNonBlocking(0)
      writeFn("\27[?2004h")
    end

    app = sessionModule.create(element, {
      columns = size.columns,
      rows = size.rows,
      color = opts.color,
      exitOnCtrlC = opts.exitOnCtrlC,
      writeFn = writeFn,
      altScreen = opts.altScreen,
      onCursor = writeCursor,
      onAltScreen = function(enabled)
        altScreenActive = enabled
        writeFn(enabled and "\27[?1049h" or "\27[?1049l")
      end,
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
        os.execute("sleep 0." .. string.format("%03d", POLL_INTERVAL_MS))
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
  if interactive then writeFn("\27[?2004l") end
  if interactive and savedTermios then tty.restoreMode(savedTermios) end
  if not ok then error(err, 0) end
  return { exitReason = exitReason }
end

return M
