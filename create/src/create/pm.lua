--[[
  JS package manager detection for the Tailwind/Vite side-build
  `create.tailwind` wires in. Nothing this package generates ever shells
  out to `npm`/`pnpm`/`bun` itself -- this only decides which one to
  recommend to the user (interactively, in the wizard) or to validate
  (non-interactively, via `--package-manager`), and to phrase "next steps"
  with the right command.

  Per this task's requirement: Tailwind support must never be offered as
  if it will silently work when nothing can actually install or build it.
  If none of npm/pnpm/bun is on PATH, the wizard visibly disables the
  Tailwind question instead of asking it, and `create.scaffold({tailwind =
  true, ...})` refuses with a clear error instead of generating a
  package.json nothing on the machine can act on.
]]

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

return M
