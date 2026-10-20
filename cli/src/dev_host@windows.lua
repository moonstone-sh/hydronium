local shell = require("clingy.windows_powershell")
local platform = require("clingy.platform")
local ffi = require("ffi")
ffi.cdef([[
uint32_t __stdcall GetCurrentProcessId(void);
void * __stdcall OpenProcess(uint32_t access, int inherit, uint32_t pid);
int __stdcall TerminateProcess(void *process, unsigned int code);
int __stdcall CloseHandle(void *handle);
uint32_t __stdcall WaitForSingleObject(void *handle, uint32_t milliseconds);
]])
local kernel = ffi.load("kernel32")
local owned_files = {}
local function cleanup(pid)
  for _, file in ipairs(owned_files[pid] or {}) do os.remove(file) end
  owned_files[pid] = nil
end
local M = { windows = true, quote = platform.quote, source_paths = require("hydronium_ink.source_files") }
function M.source_command(dir)
  return shell.command("$ErrorActionPreference='Stop'; Get-ChildItem -LiteralPath " .. shell.literal(dir)
    .. " -Recurse -File | Where-Object {$_.Extension -in '.lua','.luax'} | ForEach-Object {$_.FullName.Replace('\\','/')}")
end
function M.sleep(ms) return require("hydronium_ink.clock").sleepMs(ms) end
function M.command(argv, cwd)
  local args = {}; for i = 2, #argv do args[#args + 1] = argv[i] end
  return require("ballad.process").build_command({ tool = argv[1], args = args, cwd = cwd or "." })
end
function M.mkdir(dir, exec)
  local command = shell.command("$ErrorActionPreference='Stop';[IO.Directory]::CreateDirectory(" .. shell.literal(dir) .. ")|Out-Null")
  local ok, _, code = (exec or os.execute)(command)
  assert(ok == true or ok == 0 or code == 0, "could not create " .. dir)
end
function M.spawn(argv, opts, lua_path)
  local base = os.tmpname()
  os.remove(base)
  local wrapper = base .. ".ps1"
  local input = wrapper .. ".stdin"
  local output = opts.output_path or wrapper .. ".out"
  local error_output = output .. ".stderr"
  local file, err = io.open(wrapper, "wb")
  if not file then return nil, err end
  local environment = { CLINGY_OWNER_PID = tostring(tonumber(kernel.GetCurrentProcessId())), LUA_CPATH = "", LUA_PATH = lua_path or "" }
  -- Clingy owns a kill-on-close Job Object and watches the actual CLI owner.
  -- No cmd.exe expression is synthesized from the application's arguments.
  local child_argv = { "moon", "exec", "--dev", "--" }
  for _, value in ipairs(argv) do child_argv[#child_argv + 1] = value end
  local body = require("clingy.process").supervisor_script({ argv = child_argv, env = environment, cleanup_files = { wrapper, input } })
  file:write("\239\187\191", body); file:close()
  file = assert(io.open(input, "wb")); file:close()
  local script = "$ErrorActionPreference='Stop';$p=Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden"
    .. " -ArgumentList " .. shell.literal('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' .. wrapper .. '"')
    .. " -RedirectStandardInput " .. shell.literal(input) .. " -RedirectStandardOutput " .. shell.literal(output)
    .. " -RedirectStandardError " .. shell.literal(error_output) .. ";$p.Id"
  local pipe, open_err = (opts.popen or io.popen)(shell.command(script), "r")
  if not pipe then os.remove(wrapper); os.remove(input); return nil, open_err end
  local result = pipe:read("*a"); pipe:close()
  local pid = tonumber((result or ""):match("^%s*(%d+)%s*$"))
  if not pid then os.remove(wrapper); os.remove(input); return nil, "Windows supervisor did not return a PID" end
  owned_files[pid] = { wrapper, input }
  return pid
end
local function checked_pid(pid)
  assert(type(pid) == "number" and pid > 0 and pid % 1 == 0, "invalid process PID")
  return pid
end
function M.is_alive(pid)
  local process = kernel.OpenProcess(0x100000, 0, checked_pid(pid))
  if process == nil then cleanup(pid); return false end
  local alive = tonumber(kernel.WaitForSingleObject(process, 0)) == 0x102
  kernel.CloseHandle(process)
  if not alive then cleanup(pid) end
  return alive
end
function M.signal(pid)
  local process = kernel.OpenProcess(1, 0, checked_pid(pid))
  if process == nil then cleanup(pid); return false end
  local stopped = kernel.TerminateProcess(process, 130) ~= 0
  if stopped then kernel.WaitForSingleObject(process, 5000); cleanup(pid) end
  kernel.CloseHandle(process)
  return stopped
end
return M
