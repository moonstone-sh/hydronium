local shell = require("clingy.windows_powershell")
local M = { windows = true, quote = require("clingy.platform").quote }
function M.mkdir_command(dir)
  local p = shell.literal(dir)
  return shell.command("$ErrorActionPreference='Stop';[IO.Directory]::CreateDirectory(" .. p .. ")|Out-Null")
end
function M.directory_exists_command(dir)
  return shell.command("if([IO.Directory]::Exists(" .. shell.literal(dir) .. ")){'yes'}else{'no'}")
end
function M.list_command(dir)
  return shell.command("$ErrorActionPreference='Stop';[IO.Directory]::EnumerateFileSystemEntries(" .. shell.literal(dir) .. ")")
end
function M.cwd_command() return "cd" end
function M.find_command(name) return "where " .. M.quote(name) .. " >NUL 2>&1" end
function M.cache_age(path)
  local command = shell.command("$ErrorActionPreference='Stop';if([IO.File]::Exists(" .. shell.literal(path) .. ")){[int64]([DateTime]::UtcNow-[IO.File]::GetLastWriteTimeUtc(" .. shell.literal(path) .. ")).TotalSeconds}")
  local pipe = io.popen(command, "r")
  if not pipe then return nil end
  local age = tonumber(pipe:read("*a")); pipe:close()
  return age
end
function M.refresh(path, registry, timeout, marker, execute)
  local literal = shell.literal
  local script = "$ErrorActionPreference='Stop';$status=1;$tmp=" .. literal(path .. ".tmp") .. "+$PID;try{"
    .. "[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName(" .. literal(path) .. "))|Out-Null;"
    .. "Invoke-WebRequest -UseBasicParsing -TimeoutSec " .. timeout .. " -Uri " .. literal(registry .. "/index.toml") .. " -OutFile $tmp;"
    .. "if([IO.File]::Exists(" .. literal(path) .. ")){[IO.File]::Replace($tmp," .. literal(path) .. ",$null)}else{[IO.File]::Move($tmp," .. literal(path) .. ")};$status=0"
    .. "}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue;"
    .. (marker and ("[IO.File]::WriteAllText(" .. literal(marker) .. ",[string]$status);") or "") .. "}"
  local encoded = shell.command(script):match("EncodedCommand ([A-Za-z0-9+/=]+)$")
  return (execute or os.execute)(shell.command("Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList '-NoLogo -NoProfile -NonInteractive -EncodedCommand " .. encoded .. "'|Out-Null"))
end
return M
