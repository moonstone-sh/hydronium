-- Run only on native x86-64 Windows. Allocate a real console even when CI
-- redirects its own stdout, then inject real KEY_EVENT records.
local ffi = require("ffi")
assert(ffi.os == "Windows", "native Windows required")
local tty = require("hydronium_ink.tty_ffi")
local clock = require("hydronium_ink.clock")
ffi.cdef([[
int __stdcall AllocConsole(void);
int __stdcall FreeConsole(void);
void * __stdcall CreateFileW(const uint16_t *name, uint32_t access, uint32_t share, void *security, uint32_t disposition, uint32_t flags, void *template_file);
int __stdcall SetStdHandle(uint32_t id, void *handle);
int __stdcall CloseHandle(void *handle);
int __stdcall WriteConsoleInputW(void *handle, const HY_INPUT_RECORD *records, uint32_t count, uint32_t *written);
]])
local C = ffi.load("kernel32")
local old_in, old_out = C.GetStdHandle(-10), C.GetStdHandle(-11)
local allocated = C.AllocConsole() ~= 0
local function console(name)
  local wide = ffi.new("uint16_t[?]", #name + 1)
  for i = 1, #name do wide[i - 1] = name:byte(i) end
  local handle = C.CreateFileW(wide, 0xc0000000, 3, nil, 3, 0, nil)
  assert(handle ~= ffi.cast("void *", -1), "could not open " .. name)
  return handle
end
local input, output = console("CONIN$"), console("CONOUT$")
C.SetStdHandle(-10, input); C.SetStdHandle(-11, output)
local saved
local ok, err = xpcall(function()
  assert(ffi.sizeof("HY_INPUT_RECORD") == 20, "Windows INPUT_RECORD ABI mismatch")
  assert(ffi.sizeof("HY_SCREEN_INFO") == 22, "Windows screen buffer ABI mismatch")
  saved = tty.enableRawMode()
  local mode = ffi.new("uint32_t[1]")
  assert(C.GetConsoleMode(input, mode) ~= 0)
  assert(require("bit").band(mode[0], 7) == 0, "console still processes line input/echo/Ctrl+C")
  local size = tty.getWindowSize()
  assert(size.columns > 0 and size.rows > 0)
  local records = ffi.new("HY_INPUT_RECORD[4]")
  for i = 0, 3 do records[i].kind = 1; records[i].event.key.down = 1; records[i].event.key.repeat_count = 1 end
  records[0].event.key.character = 0x03bb -- lambda
  records[1].event.key.key = 0x26 -- up
  records[2].event.key.character = 3 -- Ctrl+C is data, not process termination
  records[3].event.key.character = 113 -- q
  local written = ffi.new("uint32_t[1]")
  assert(C.WriteConsoleInputW(input, records, 4, written) ~= 0 and written[0] == 4)
  assert(tty.pollReadable(0, 1000))
  assert(tty.readAvailable(0, 4096) == "\206\187\27[A\3q", "native key translation failed")
  assert(tty.writeAll(1, "\27[32mHydronium Windows console\27[0m\r\n"))
  local start = clock.nowMs(); clock.sleepMs(20)
  assert(clock.nowMs() - start >= 10, "Windows clock measures CPU time")
  tty.restoreMode(saved)
  assert(C.GetConsoleMode(input, mode) ~= 0 and mode[0] == saved.input, "input mode was not restored")
  assert(tonumber(C.GetConsoleOutputCP()) == saved.codepage, "output codepage was not restored")
end, debug.traceback)
if saved then tty.restoreMode(saved) end
C.SetStdHandle(-10, old_in); C.SetStdHandle(-11, old_out)
C.CloseHandle(input); C.CloseHandle(output)
if allocated then C.FreeConsole() end
assert(ok, err)
print("PASS: native Windows console, Unicode, ANSI, raw mode, restoration and clock")
