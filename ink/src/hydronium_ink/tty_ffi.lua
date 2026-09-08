--[[
  hydronium_ink.tty_ffi -- raw POSIX terminal control via LuaJIT FFI:
  entering/restoring raw mode, polling the real terminal size, and
  non-blocking stdin reads. This is genuinely new infrastructure in this
  workspace -- no existing raw-mode/termios/ioctl implementation was
  found anywhere else here (checked: clingy's presentation/composer*.lua
  uses "raw_mode" only as an output-verbosity-string name, not real TTY
  control).

  PLATFORM SCOPE, stated plainly: POSIX only (macOS + Linux via termios).
  Windows needs a structurally different mechanism (Win32 console API,
  no termios there at all) -- not implemented, not silently pretended to
  work; `enableRawMode()` raises a clear error on `ffi.os == "Windows"`.

  VERIFICATION HONESTY: the macOS `struct termios` layout below was
  checked against this machine's real SDK header
  (`$(xcrun --show-sdk-path)/usr/include/sys/termios.h`) and its exact
  flag/ioctl constants (TIOCGWINSZ, ICANON, etc.) were confirmed by
  compiling and running a tiny real C program against that same SDK --
  see this file's own git history / the session that added it for the
  literal commands. It is real and tested on this host.

  The Linux layout was checked against real glibc headers (via this
  repo's own vendored Zig toolchain's bundled cross-compilation headers,
  `zig/lib/zig/libc/include/generic-glibc/bits/termios*.h` -- the actual
  upstream glibc struct/constant definitions, not guessed from memory)
  but **could not be run-tested on this machine** (this host is macOS).
  This is a real, lower assurance level than the macOS path or than the
  Yoga native build's cross-compiled targets (those are at least
  compile-checked by `zig build`; there is no equivalent compile-check
  for an FFI cdef, which LuaJIT only parses at runtime on whatever host
  actually loads it). Treat the Linux path as best-effort until it's
  actually run on Linux.

  Uses `cfmakeraw()` (a real libc function on both platforms, POSIX/BSD
  lineage, present in glibc too) to compute the correct raw-mode flag
  bits, rather than hand-replicating ICANON/ECHO/ISIG/etc. bit math here
  -- only the struct LAYOUT needs to be platform-correct for
  tcgetattr/cfmakeraw/tcsetattr to work; the flag values themselves are
  never read or written by this file directly.
--]]

local ffi = require("ffi")
local bit = require("bit")

if ffi.os == "Windows" then
  error(
    "hydronium_ink.tty_ffi: POSIX-only in this version (termios has no"
      .. " Windows equivalent -- Win32 console API would be a separate,"
      .. " unimplemented code path). See this file's own doc comment.",
    0
  )
end

if ffi.os == "OSX" then
  ffi.cdef([[
typedef unsigned long tcflag_t;
typedef unsigned char cc_t;
typedef unsigned long speed_t;

struct termios {
  tcflag_t c_iflag;
  tcflag_t c_oflag;
  tcflag_t c_cflag;
  tcflag_t c_lflag;
  cc_t     c_cc[20];
  speed_t  c_ispeed;
  speed_t  c_ospeed;
};
]])
else -- Linux (best-effort, see doc comment above)
  ffi.cdef([[
typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
typedef unsigned int speed_t;

struct termios {
  tcflag_t c_iflag;
  tcflag_t c_oflag;
  tcflag_t c_cflag;
  tcflag_t c_lflag;
  cc_t     c_line;
  cc_t     c_cc[32];
  speed_t  c_ispeed;
  speed_t  c_ospeed;
};
]])
end

ffi.cdef([[
int tcgetattr(int fd, struct termios *termios_p);
int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
void cfmakeraw(struct termios *termios_p);

struct winsize {
  unsigned short ws_row;
  unsigned short ws_col;
  unsigned short ws_xpixel;
  unsigned short ws_ypixel;
};
int ioctl(int fd, unsigned long request, ...);

int fcntl(int fd, int cmd, ...);

typedef struct { long tv_sec; int tv_usec; } timeval_t;
typedef struct { unsigned char bytes[128]; } fd_set_t;
int select(int nfds, fd_set_t *readfds, fd_set_t *writefds, fd_set_t *errorfds, timeval_t *timeout);

long read(int fd, void *buf, unsigned long count);
]])

local C = ffi.C

-- TCSANOW: same numeric value (0) on both macOS and Linux -- verified
-- against both the real macOS SDK header and the Linux glibc header
-- pulled from this repo's own vendored Zig toolchain (see the doc
-- comment above).
local TCSANOW = 0

-- TIOCGWINSZ: platform-specific ioctl request number (BSD/macOS encodes
-- direction+size+group+num into the value itself; Linux uses a flat
-- historical constant). Verified: macOS value from a real compiled C
-- program against this host's own SDK
-- (`printf("0x%lx", TIOCGWINSZ)` -> 0x40087468); Linux value from the
-- real kernel uapi header bundled with this repo's own Zig toolchain
-- (`asm-generic/ioctls.h`), not run-tested here.
local TIOCGWINSZ = ffi.os == "OSX" and 0x40087468 or 0x5413

-- F_GETFL/F_SETFL: identical values on macOS and Linux (both trace to
-- the same historical BSD fcntl.h numbering).
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = ffi.os == "OSX" and 0x00000004 or 0x00000800 -- Linux's O_NONBLOCK differs from BSD's

local M = {}

--- @class hydronium_ink.SavedTermios
--- @field private raw ffi.cdata* The real `struct termios *` saved before entering raw mode.

--- Puts fd 0 (stdin) into raw mode (no line buffering, no echo, no
--- signal-generating control chars -- see this module's own doc comment
--- for why `cfmakeraw()` is used instead of hand-computed flags) and
--- returns the previous settings so `restore()` can put them back.
--- @return hydronium_ink.SavedTermios
function M.enableRawMode()
  local original = ffi.new("struct termios[1]")
  if C.tcgetattr(0, original) ~= 0 then
    error("hydronium_ink.tty_ffi: tcgetattr failed", 0)
  end

  local raw = ffi.new("struct termios[1]")
  ffi.copy(raw, original, ffi.sizeof("struct termios"))
  C.cfmakeraw(raw)
  if C.tcsetattr(0, TCSANOW, raw) ~= 0 then
    error("hydronium_ink.tty_ffi: tcsetattr(raw) failed", 0)
  end

  return { raw = original }
end

--- Restores terminal settings saved by `enableRawMode()`. Safe to call
--- more than once is NOT guaranteed (tcsetattr on an fd that's since
--- been closed would fail) -- callers (render.lua) call this exactly
--- once, on the way out, including from a pcall-wrapped error path.
--- @param saved hydronium_ink.SavedTermios
function M.restoreMode(saved)
  C.tcsetattr(0, TCSANOW, saved.raw)
end

--- @class hydronium_ink.WindowSize
--- @field columns integer
--- @field rows integer

--- Real terminal size via `ioctl(TIOCGWINSZ)`, not `$COLUMNS`/`$LINES`
--- (which are only ever set once, at shell-launch time, and never
--- updated on a live resize).
--- @return hydronium_ink.WindowSize
function M.getWindowSize()
  local ws = ffi.new("struct winsize[1]")
  -- fd 0 (stdin), not 1: this module already reads raw input from fd 0
  -- (see readAvailable/pollReadable), so querying size from the same fd
  -- is guaranteed coherent with that regardless of whether a caller
  -- happens to redirect stdout elsewhere -- discovered directly by a
  -- real test harness where stdout was redirected to a log file but
  -- stdin stayed attached to the real pty, which made fd-1-based
  -- querying fail with ENOTTY while fd 0 succeeded.
  if C.ioctl(0, TIOCGWINSZ, ws) ~= 0 then
    error("hydronium_ink.tty_ffi: ioctl(TIOCGWINSZ) failed", 0)
  end
  return { columns = ws[0].ws_col, rows = ws[0].ws_row }
end

--- Sets `fd` non-blocking (`read()` returns immediately with no data
--- available rather than blocking the whole event loop -- see
--- render.lua's own loop, which polls stdin alongside resize checks and
--- host.flush() on every iteration).
--- @param fd integer
function M.setNonBlocking(fd)
  -- The vararg `int cmd`-dependent third argument MUST be explicitly
  -- cast to `int` (`ffi.new("int", ...)`), not passed as a plain Lua
  -- number -- LuaJIT FFI's default vararg promotion for a bare Lua
  -- number is `double`, but fcntl's real C variadic contract reads this
  -- argument via `va_arg(ap, int)`. Passing a plain number here was
  -- confirmed for real to silently corrupt the call: fcntl still
  -- returned success (0), but a subsequent F_GETFL showed the flags
  -- completely unchanged -- O_NONBLOCK was never actually set, and the
  -- following read() blocked for real (caught via a live tmux pane
  -- test, not reasoned about).
  local flags = C.fcntl(fd, F_GETFL, ffi.new("int", 0))
  if flags < 0 then
    error("hydronium_ink.tty_ffi: fcntl(F_GETFL) failed", 0)
  end
  local newFlags = ffi.new("int", bit.bor(flags, O_NONBLOCK))
  if C.fcntl(fd, F_SETFL, newFlags) ~= 0 then
    error("hydronium_ink.tty_ffi: fcntl(F_SETFL, O_NONBLOCK) failed", 0)
  end
end

--- Blocks for up to `timeoutMs` waiting for `fd` to become readable.
--- Used to poll stdin without busy-looping the CPU while still checking
--- window size / flushing paint on every render.lua loop iteration even
--- when no input arrives.
--- @param fd integer
--- @param timeoutMs integer
--- @return boolean readable
function M.pollReadable(fd, timeoutMs)
  local readfds = ffi.new("fd_set_t[1]")
  ffi.fill(readfds, ffi.sizeof("fd_set_t"), 0)
  -- FD_SET(fd, &readfds): sets bit (fd % 8) of byte (fd / 8). Only ever
  -- called with fd == 0 (stdin) in this module's own usage, but written
  -- generally rather than hardcoding byte 0 bit 0.
  local byte_index = math.floor(fd / 8)
  local bit_index = fd % 8
  readfds[0].bytes[byte_index] = bit.bor(readfds[0].bytes[byte_index], bit.lshift(1, bit_index))

  local tv = ffi.new("timeval_t[1]")
  tv[0].tv_sec = math.floor(timeoutMs / 1000)
  tv[0].tv_usec = (timeoutMs % 1000) * 1000

  local result = C.select(fd + 1, readfds, nil, nil, tv)
  return result > 0
end

--- Non-blocking read of up to `maxBytes` from `fd`. Returns `nil` (not
--- an empty string) when nothing is currently available -- distinct
--- from a real EOF, which this module does not need to distinguish for
--- render.lua's own polling loop (a closed stdin simply never has
--- anything to read again).
--- @param fd integer
--- @param maxBytes integer
--- @return string|nil
function M.readAvailable(fd, maxBytes)
  local buf = ffi.new("char[?]", maxBytes)
  local n = C.read(fd, buf, maxBytes)
  if n <= 0 then
    return nil
  end
  return ffi.string(buf, n)
end

return M
