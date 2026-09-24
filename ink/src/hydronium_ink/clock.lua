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

  struct hydronium_ink_timespec { time_t tv_sec; long tv_nsec; };
  int nanosleep(const struct hydronium_ink_timespec *req, struct hydronium_ink_timespec *rem);
]])

local M = {}

local tv = ffi.new("struct hydronium_ink_timeval")

--- @return number Milliseconds since the Unix epoch (real wall-clock time, see this module's own doc comment).
function M.nowMs()
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) * 1000 + tonumber(tv.tv_usec) / 1000
end

local req = ffi.new("struct hydronium_ink_timespec")
local rem = ffi.new("struct hydronium_ink_timespec")

--- Sleeps for `ms` milliseconds without leaving the process.
---
--- Replaces `os.execute("sleep 0.033")` in render.lua's non-interactive
--- pacing branch. That forked a shell AND a `sleep` binary roughly thirty
--- times a second for the lifetime of the process -- pure overhead in exactly
--- the contexts that path serves (CI, piped output, anything whose stdout is
--- not a tty). It also perturbed the very thing it was pacing: forking burns
--- real CPU in the parent, which is why a redirected run appeared to animate
--- while a real terminal sat frozen, back when animation timing still read
--- `os.clock()`.
---
--- EINTR is handled rather than ignored: nanosleep returns -1 with the
--- unslept remainder written to `rem` when a signal lands mid-sleep (SIGWINCH
--- on a terminal resize is an ordinary occurrence here), so the remainder is
--- re-slept. Without that, a resize would cut the pace short and spin the
--- loop hot.
--- @param ms number
function M.sleepMs(ms)
  if not ms or ms <= 0 then return end
  local whole = math.floor(ms / 1000)
  req.tv_sec = whole
  req.tv_nsec = math.floor((ms - whole * 1000) * 1e6)
  while ffi.C.nanosleep(req, rem) ~= 0 do
    -- Any failure other than "interrupted" would repeat forever; the only
    -- documented errors are EINTR and EINVAL, and EINVAL cannot happen for a
    -- normalized tv_nsec, so treat a zero remainder as "done" and bail.
    if rem.tv_sec <= 0 and rem.tv_nsec <= 0 then return end
    req.tv_sec, req.tv_nsec = rem.tv_sec, rem.tv_nsec
  end
end

return M
