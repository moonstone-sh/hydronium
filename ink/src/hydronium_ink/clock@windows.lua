-- Monotonic elapsed time and in-process waiting on native Windows.
local ffi = require("ffi")
ffi.cdef([[
int __stdcall QueryPerformanceCounter(int64_t *value);
int __stdcall QueryPerformanceFrequency(int64_t *value);
void __stdcall GetSystemTimeAsFileTime(uint64_t *value);
void __stdcall Sleep(uint32_t milliseconds);
]])
local kernel = ffi.load("kernel32")
local frequency, counter = ffi.new("int64_t[1]"), ffi.new("int64_t[1]")
assert(kernel.QueryPerformanceFrequency(frequency) ~= 0, "Ink: performance counter unavailable")
local ticks_per_ms = tonumber(frequency[0]) / 1000
local wall = ffi.new("uint64_t[1]")
kernel.GetSystemTimeAsFileTime(wall)
assert(kernel.QueryPerformanceCounter(counter) ~= 0, "Ink: performance counter failed")
-- Preserve Unix-millisecond timestamps while measuring intervals monotonically.
local epoch = tonumber(wall[0]) / 10000 - 11644473600000 - tonumber(counter[0]) / ticks_per_ms
return {
  nowMs = function()
    assert(kernel.QueryPerformanceCounter(counter) ~= 0, "Ink: performance counter failed")
    return epoch + tonumber(counter[0]) / ticks_per_ms
  end,
  sleepMs = function(ms) if ms and ms > 0 then kernel.Sleep(math.ceil(ms)) end end,
}
