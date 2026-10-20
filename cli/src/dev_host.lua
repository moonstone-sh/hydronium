local M = { windows = false }
function M.quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
function M.source_command(dir) return "find " .. M.quote(dir) .. " -type f \\( -name '*.lua' -o -name '*.luax' \\) 2>/dev/null" end
function M.sleep(ms) return require("hydronium_ink.clock").sleepMs(ms) end
return M
