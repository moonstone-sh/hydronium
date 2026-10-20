-- Exercise the Windows backend on every host. The API boundary is injected;
-- native Windows CI additionally runs it against a real allocated console.
local runner = require("tests.runner")
local describe, it, check = runner.describe, runner.it, runner.assert
local ffi = require("ffi")
local queue, writes, modes, fail_output = {}, {}, {}, false
local api = {}
function api.GetStdHandle(id) return id end
function api.GetConsoleMode(handle, value) value[0] = handle == -10 and 7 or 3; return 1 end
function api.GetConsoleOutputCP() return 437 end
function api.SetConsoleOutputCP(value) writes[#writes + 1] = { "codepage", value }; return 1 end
function api.SetConsoleMode(handle, value)
  modes[#modes + 1] = { handle, value }
  if fail_output and handle == -11 then fail_output = false; return 0 end
  return 1
end
function api.GetNumberOfConsoleInputEvents(_, value) value[0] = #queue; return 1 end
function api.ReadConsoleInputW(_, records, _, count)
  count[0] = #queue
  for i, item in ipairs(queue) do
    records[i - 1].kind = item.kind or 1
    local key = records[i - 1].event.key
    key.down, key.key, key.character, key.repeat_count, key.controls = item.down == false and 0 or 1, item.key or 0, item.char or 0, item.count or 1, item.controls or 0
  end
  queue = {}
  return 1
end
function api.WaitForSingleObject() return 0x102 end
function api.WriteFile(_, bytes, size, count)
  count[0] = math.min(2, size)
  writes[#writes + 1] = bytes:sub(1, tonumber(count[0]))
  return 1
end
local real_load = ffi.load
ffi.load = function(name, ...) if name == "kernel32" then return api end; return real_load(name, ...) end
local ok, tty = pcall(assert(loadfile("ink/src/hydronium_ink/tty_ffi@windows.lua")))
ffi.load = real_load
assert(ok, tty)

describe("Windows console adapter", function()
  it("restores modes and UTF-8 codepage after setup failure", function()
    queue, writes, modes, fail_output = {}, {}, {}, true
    check.falsy(pcall(tty.enableRawMode))
    check.equal(modes[#modes - 1][2], 7)
    check.equal(modes[#modes][2], 3)
    check.equal(writes[#writes][2], 437)
  end)
  it("decodes key repeats, Unicode surrogate pairs, modifiers and Ctrl+C", function()
    tty.enableRawMode()
    queue = {
      { kind = 4 }, { char = 97, count = 2 }, { key = 0x26 },
      { char = 0xd83d }, { char = 0xde80 }, { key = 0x27, controls = 0x10 },
      { char = 3 }, { key = 9, controls = 0x10 }, { char = 120, down = false },
    }
    check.truthy(tty.pollReadable(0, 1))
    check.equal(tty.readAvailable(0, 4096), "aa\27[A\240\159\154\128\27[1;2C\3\27[Z")
    check.equal(tty.readAvailable(0, 4096), nil)
  end)
  it("does not block on resize and focus records", function()
    tty.enableRawMode()
    queue = { { kind = 4 }, { kind = 16 } }
    check.falsy(tty.pollReadable(0, 1))
  end)
  it("finishes short writes and restores only once", function()
    writes, modes = {}, {}
    local saved = tty.enableRawMode()
    local complete, count = tty.writeAll(1, "abcdef")
    check.truthy(complete); check.equal(count, 6)
    local output = {}; for _, value in ipairs(writes) do if type(value) == "string" then output[#output + 1] = value end end
    check.equal(table.concat(output), "abcdef")
    tty.restoreMode(saved)
    local n = #modes
    tty.restoreMode(saved)
    check.equal(#modes, n)
  end)
end)
