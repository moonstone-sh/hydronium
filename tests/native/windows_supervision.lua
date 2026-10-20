local ffi = require("ffi")
assert(ffi.os == "Windows", "native Windows required")
local root = assert(arg[0]:gsub("\\", "/"):match("^(.*)/tests/native/[^/]+$"))
package.path = root .. "/cli/src/?.lua;" .. package.path
local host = require("dev_platform")
local clock = require("hydronium_ink.clock")
local probe, pidfile, output = "supervised probe.lua", "supervised-child.pid", "supervised.out"
local file = assert(io.open(probe, "wb"))
file:write([=[
local ffi = require("ffi")
ffi.cdef([[uint32_t __stdcall GetCurrentProcessId(void); void __stdcall Sleep(uint32_t ms);]])
local C = ffi.load("kernel32")
assert(arg[2] == "two words" and arg[3] == "a&b" and arg[4] == 'quote"x', "argument boundaries changed")
local file = assert(io.open(arg[1], "wb")); file:write(tostring(tonumber(C.GetCurrentProcessId()))); file:close()
while true do C.Sleep(50) end
]=])
file:close()
local pid, child
local ok, err = xpcall(function()
  local reason
  pid, reason = host.spawn({ "luajit", probe, pidfile, "two words", "a&b", 'quote"x' }, { output_path = output }, os.getenv("LUA_PATH"))
  assert(pid, reason)
  local deadline = clock.nowMs() + 20000
  repeat
    local entry = io.open(pidfile, "rb")
    if entry then child = tonumber(entry:read("*a")); entry:close() end
    if child then break end
    assert(host.is_alive(pid), "Windows supervisor exited before the child started; inspect " .. output .. ".stderr")
    clock.sleepMs(50)
  until clock.nowMs() >= deadline
  assert(child and host.is_alive(child), "supervised child never became live")
  assert(host.signal(pid), "could not stop Windows supervisor")
  deadline = clock.nowMs() + 5000
  while host.is_alive(child) and clock.nowMs() < deadline do clock.sleepMs(20) end
  assert(not host.is_alive(child), "Job Object left a descendant running")
end, debug.traceback)
if pid then host.signal(pid) end
for _, filename in ipairs({probe,pidfile,output,output .. ".stderr"}) do os.remove(filename) end
assert(ok, err)
print("PASS: Windows dev supervision preserves argv and reaps the owned process tree")
