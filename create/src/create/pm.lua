-- JS package-manager detection and generated command adaptation.

local M = {}

-- Preference order when more than one is available and the caller hasn't
-- said which to use (e.g. `--tailwind` with no `--package-manager` on a
-- machine that has several) -- NOT the order they happen to appear on
-- PATH. pnpm and bun are both meaningfully faster than npm for a
-- Vite-only devDependency set; npm is the universal fallback every Node
-- install ships.
M.candidates = { "pnpm", "bun", "npm" }

local function has_command(name)
  local ok = os.execute(string.format("command -v %s >/dev/null 2>&1", name))
  return ok == true or ok == 0
end

--- Every JS package manager found on PATH, in `M.candidates` order.
--- Empty when none are available -- callers must treat that as "the
--- Tailwind/Vite build is unavailable on this machine", never fall back
--- to a name that doesn't actually run.
function M.detect()
  local found = {}
  for _, name in ipairs(M.candidates) do
    if has_command(name) then found[#found + 1] = name end
  end
  return found
end

function M.is_known(name)
  for _, candidate in ipairs(M.candidates) do
    if candidate == name then return true end
  end
  return false
end

local COMMANDS = {
  npm = { install = "npm install", run = "npm run %s" },
  pnpm = { install = "pnpm install", run = "pnpm %s" },
  bun = { install = "bun install", run = "bun run %s" },
}

function M.install_command(name)
  return (COMMANDS[name] or COMMANDS.npm).install
end

function M.run_command(name, script)
  return string.format((COMMANDS[name] or COMMANDS.npm).run, script)
end

--- Apply after Vite and Tailwind so their commands and documentation agree.
function M.apply(files, name)
  name = name or "npm"
  assert(M.is_known(name), "unknown package manager: " .. tostring(name))
  local paths = { "moonstone.toml", "README.md" }
  for path in pairs(files) do
    if path:match("^scripts/.*%.mjs$") then paths[#paths + 1] = path end
  end
  for _, path in ipairs(paths) do
    if files[path] then
      files[path] = files[path]:gsub("%f[%a]npm install", function() return M.install_command(name) end)
        :gsub("%f[%a]npm run ([%w_-]+)", function(script) return M.run_command(name, script) end)
      if name ~= "npm" then
        files[path] = files[path]:gsub("npx %-%-yes serve", name == "bun" and "bunx serve" or "pnpm dlx serve")
      end
    end
  end
  if name == "bun" and files["package.json"] then
    files["package.json"] = files["package.json"]:gsub("node scripts/", "bun scripts/")
  end
  if files["scripts/dev.mjs"] and not files["scripts/dev.mjs"]:find("HYDRONIUM_PACKAGE_MANAGER:", 1, true) then
    files["scripts/dev.mjs"] = files["scripts/dev.mjs"]:gsub("HYDRONIUM_JS_RUNTIME:",
      'HYDRONIUM_PACKAGE_MANAGER: "' .. name .. '", HYDRONIUM_JS_RUNTIME:')
  end
  return files
end

return M
