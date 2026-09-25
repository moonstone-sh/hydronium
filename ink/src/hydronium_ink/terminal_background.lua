--[[
  hydronium_ink.terminal_background -- OSC 11 ("what is your background
  color?") detection.

  This is deliberately terminal-GENERIC infrastructure, not app-specific: any
  Hydronium Ink app that wants to tune its own colors against the real
  terminal background (see cli/src/ui/search_bar.lua for the reference
  consumer) needs the same query/parse/timeout machinery, so it lives here
  rather than being reinvented per-app. render.lua's own OSC evaluation
  comment already flagged OSC 10/11 QUERY (not SET) as "the more likely
  candidate to revisit" once round-trip OSC-response parsing existed
  anywhere in this package -- this module is that round trip.

  PROTOCOL: writes `\27]11;?\27\` to fd 1 and reads the terminal's own reply
  off fd 0 -- `\27]11;rgb:RRRR/GGGG/BBBB` terminated by either BEL (`\7`,
  the older/wider-compatibility terminator) or ST (`\27\`, the "modern"
  one). Each channel is 1-4 hex digits (terminals vary: some reply "ff",
  others "ffff") and is normalized by treating it as a fraction of its own
  max value, not by truncating/padding blindly.

  NEVER LEAKS REPLY BYTES INTO APP INPUT: `detect()` reads directly off fd 0
  itself, via the same raw, non-blocking primitives render.lua's own input
  loop uses (`tty_ffi.pollReadable`/`readAvailable`) -- bytes it consumes
  here never reach `session:write()`/the key parser. Only the OSC 11 reply
  itself is discarded; any other bytes read in the same window (e.g. a key
  the user genuinely typed while this was querying) are handed back as
  `leftover` for the caller to forward into the session once one exists.
  This is why `detect()` must be called ONCE, at startup, before a session's
  normal input loop starts polling fd 0 -- calling it mid-session would
  race the main loop for the same bytes.

  TTY-GATED: only queries when BOTH stdin and stdout are TTYs (querying a
  pipe/redirect either hangs waiting for a reply that will never come, or --
  worse -- corrupts whatever real data is flowing through a redirected
  stdin/stdout). Falls back to `COLORFGBG` (set by some terminals/multiplexers
  themselves, e.g. tmux) when the OSC 11 round trip is unavailable or times
  out, and to `nil` (caller's own default, e.g. "assume dark") when neither
  source is available.
--]]

local ffi = require("ffi")
local oklab = require("hydronium_oklab_utils")
local ink_color = require("hydronium_ink.color")

ffi.cdef([[int isatty(int fd);]])

local M = {}

local DEFAULT_TIMEOUT_MS = 200
local POLL_SLICE_MS = 20

--- Parses an OSC 11 background-color reply out of `bytes`, which may
--- contain other bytes before/after it (or none at all). Pure/no I/O, so
--- it is unit-testable directly against synthetic byte strings.
--- @param bytes string
--- @return hydronium_oklab_utils.Color|nil color, integer|nil matchStart, integer|nil matchEnd
function M.parse_response(bytes)
  local s, e, body = bytes:find("\27%]11;(.-)\7")
  if not s then s, e, body = bytes:find("\27%]11;(.-)\27\\") end
  if not s then return nil, nil, nil end

  local rh, gh, bh = body:match("^rgb:(%x%x?%x?%x?)/(%x%x?%x?%x?)/(%x%x?%x?%x?)$")
  if not rh then return nil, nil, nil end

  local function channel(hex)
    local max = 16 ^ #hex - 1
    return math.floor(tonumber(hex, 16) / max * 255 + 0.5)
  end

  return oklab.srgb(channel(rh), channel(gh), channel(bh)), s, e
end

--- `COLORFGBG` fallback: some terminals/multiplexers (notably tmux, and
--- terminals launched under it) set this to "fg;bg" ANSI16 slot indices
--- without needing any query at all. Only the trailing (background) index
--- is used, and only when it names one of the 16 slots this module already
--- has an assumed RGB for (`hydronium_ink.color.ansi16_rgb`).
--- @return hydronium_oklab_utils.Color|nil
local function from_colorfgbg()
  local raw = os.getenv("COLORFGBG")
  if not raw then return nil end
  local index = tonumber(raw:match("(%d+)%s*$"))
  if not index or index < 0 or index > 15 then return nil end
  local rgb = ink_color.ansi16_rgb(index)
  if not rgb then return nil end
  return oklab.srgb(rgb[1], rgb[2], rgb[3])
end
M.from_colorfgbg = from_colorfgbg

--- Detects the real terminal background color via an OSC 11 round trip,
--- falling back to `COLORFGBG` and then to `nil`. See this file's own top
--- comment for the full protocol/leak/TTY-gating rationale.
---
--- Every I/O primitive is injectable (`opts.isatty`/`writeFn`/
--- `pollReadable`/`readAvailable`) so the no-TTY and timeout paths are
--- unit-testable without a real terminal and without a real sleep -- a
--- stubbed `pollReadable` that always returns `false` exhausts the
--- (injected, tiny) timeout budget in a handful of synchronous calls.
--- @param opts? { timeoutMs?: integer, isatty?: fun(fd:integer):boolean, writeFn?: fun(bytes:string), pollReadable?: fun(fd:integer, ms:integer):boolean, readAvailable?: fun(fd:integer, max:integer):string|nil }
--- @return hydronium_oklab_utils.Color|nil color, string|nil leftover Bytes read that were not the OSC 11 reply -- forward these into the session once one exists.
function M.detect(opts)
  opts = opts or {}
  local isatty = opts.isatty or function(fd) return ffi.C.isatty(fd) == 1 end

  if not (isatty(0) and isatty(1)) then
    return from_colorfgbg(), nil
  end

  -- Real primitives are required from here on (either genuinely provided,
  -- or this really is an interactive TTY and tty_ffi's own POSIX-only
  -- requirement is already satisfied by render.lua having gotten this far).
  -- NOT `(opts.writeFn and ...) and nil or require(...)` -- that idiom
  -- breaks the moment the "then" branch is nil, which is exactly this case.
  local tty
  if not (opts.writeFn and opts.pollReadable and opts.readAvailable) then
    tty = require("hydronium_ink.tty_ffi")
  end
  local writeFn = opts.writeFn or function(bytes) tty.writeAll(1, bytes) end
  local pollReadable = opts.pollReadable or tty.pollReadable
  local readAvailable = opts.readAvailable or tty.readAvailable
  local timeoutMs = opts.timeoutMs or DEFAULT_TIMEOUT_MS

  writeFn("\27]11;?\27\\")

  local buf = ""
  local waited = 0
  while waited < timeoutMs do
    if pollReadable(0, POLL_SLICE_MS) then
      local chunk = readAvailable(0, 256)
      if chunk then
        buf = buf .. chunk
        local color, s, e = M.parse_response(buf)
        if color then
          local leftover = buf:sub(1, s - 1) .. buf:sub(e + 1)
          return color, leftover ~= "" and leftover or nil
        end
      end
    end
    waited = waited + POLL_SLICE_MS
  end

  -- Timed out without a (parseable) reply. Whatever was read is real input,
  -- not this module's own bytes -- hand it back rather than dropping it.
  local fallback = from_colorfgbg()
  return fallback, buf ~= "" and buf or nil
end

return M
