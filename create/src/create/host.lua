local M = { windows = false }
function M.quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
function M.mkdir_command(dir) return "mkdir -p " .. M.quote(dir) end
function M.directory_exists_command(dir) return "[ -d " .. M.quote(dir) .. " ] && echo yes || echo no" end
function M.list_command(dir) return "ls -A " .. M.quote(dir) .. " 2>/dev/null" end
function M.cwd_command() return "pwd -P" end
function M.find_command(name) return "command -v " .. M.quote(name) .. " >/dev/null 2>&1" end
return M
