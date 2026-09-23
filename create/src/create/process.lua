local process = {}

local function status_code(status, _, code)
  if type(status) == "number" then return status end
  if status == true then return 0 end
  return code or 1
end

function process.is_windows()
  return package.config:sub(1, 1) == "\\" or os.getenv("OS") == "Windows_NT"
end

local function posix_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Lua 5.1 has no argv-based process API. On Windows, reject cmd.exe syntax
-- instead of claiming that ordinary double-quoting makes arbitrary input safe.
local function windows_value(value, subject)
  value = tostring(value)
  if value:find("\r", 1, true) or value:find("\n", 1, true) or value:find("\0", 1, true) then
    error("Windows process " .. subject .. " cannot contain a newline or NUL", 3)
  end
  if value:find('[&|<>()^"!%%]') then
    error("Windows process " .. subject .. " contains a cmd.exe metacharacter", 3)
  end
  if value:sub(-1) == "\\" then
    error("Windows process " .. subject .. " cannot end with a backslash; use forward slashes", 3)
  end
  return value
end

local function windows_quote(value, subject)
  return '"' .. windows_value(value, subject) .. '"'
end

function process.build_command(opts, platform)
  assert(type(opts) == "table" and type(opts.tool) == "string" and opts.tool ~= "", "process tool is required")
  platform = platform or (process.is_windows() and "windows" or "posix")
  if platform == "windows" then
    local parts = { windows_quote(opts.tool, "tool") }
    for index, value in ipairs(opts.args or {}) do
      parts[#parts + 1] = windows_quote(value, "argument " .. index)
    end
    return 'cmd /d /v:off /s /c "setlocal DisableDelayedExpansion && pushd '
      .. windows_quote(opts.cwd or ".", "cwd") .. " && " .. table.concat(parts, " ") .. '"'
  end
  local parts = { posix_quote(opts.tool) }
  for _, value in ipairs(opts.args or {}) do parts[#parts + 1] = posix_quote(value) end
  return "cd " .. posix_quote(opts.cwd or ".") .. " && " .. table.concat(parts, " ")
end

function process.run(opts)
  local command = process.build_command(opts)
  local ok, why, code = os.execute(command)
  return { exit_code = status_code(ok, why, code), command = command, stdout = "", stderr = "" }
end

function process.capture(opts)
  local stdout_path, stderr_path = os.tmpname(), os.tmpname()
  local command = process.build_command(opts)
  local platform = process.is_windows() and "windows" or "posix"
  if platform == "windows" then
    command = command .. " > " .. windows_quote(stdout_path, "stdout path")
      .. " 2> " .. windows_quote(stderr_path, "stderr path")
  else
    command = command .. " > " .. posix_quote(stdout_path) .. " 2> " .. posix_quote(stderr_path)
  end
  local ok, why, code = os.execute(command)
  local function read(path)
    local file = io.open(path, "rb")
    if not file then return "" end
    local value = file:read("*a") or ""
    file:close()
    return value:gsub("%s+$", "")
  end
  local result = {
    exit_code = status_code(ok, why, code),
    command = command,
    stdout = read(stdout_path),
    stderr = read(stderr_path),
  }
  os.remove(stdout_path)
  os.remove(stderr_path)
  return result
end

return process
