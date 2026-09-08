--[[
  hydronium_ink.clock -- a real wall-clock millisecond timestamp,
  POSIX-only (`gettimeofday`, standard `struct timeval` layout on both
  macOS and Linux -- two `long`s, no platform-specific struct-size
  divergence the way tty_ffi.lua's `struct termios` has).

  WHY NOT `os.clock()`: it returns CPU time consumed by this process, not
  wall-clock time -- verified for real (a `gettimeofday`-based measurement
  across a real 250ms `sleep` reported ~261ms elapsed; `os.clock()` across
  the same sleep reported ~0.5ms, since the process was blocked, not
  burning CPU). render.lua's event loop spends nearly all its life
  blocked in `select()`/a paced sleep -- exactly the case `os.clock()`
  gets wrong -- so anything timing real elapsed wall time (useAnimation's
  ticker below, and keys.lua's own ESC-alone disambiguation timeout) must
  use this instead.

  STATED SIMPLIFICATION: `gettimeofday` is wall-clock, not monotonic --
  a system clock adjustment (NTP step, manual clock change) could in
  theory produce a negative or inflated delta. Not guarded against here;
  a real monotonic clock (`clock_gettime(CLOCK_MONOTONIC, ...)`) would
  need a platform-specific clock-id constant (differs between macOS and
  Linux), which this module deliberately avoids taking on for what is,
  in practice, keypress-timeout and animation-frame timing -- not
  correctness-critical scheduling.
--]]

local ffi = require("ffi")

if ffi.os == "Windows" then
  error("hydronium_ink.clock: POSIX only (gettimeofday) -- see this module's own doc comment", 2)
end

ffi.cdef([[
  typedef long time_t;
  typedef long suseconds_t;
  struct hydronium_ink_timeval { time_t tv_sec; suseconds_t tv_usec; };
  int gettimeofday(struct hydronium_ink_timeval *tv, void *tz);
]])

local M = {}

local tv = ffi.new("struct hydronium_ink_timeval")

--- @return number Milliseconds since the Unix epoch (real wall-clock time, see this module's own doc comment).
function M.nowMs()
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) * 1000 + tonumber(tv.tv_usec) / 1000
end

return M
