--[[
  hydronium-create wizard: shared step catalog, validation and small pure
  helpers -- extracted out of wizard_app.lua (the full-pane stepped wizard)
  so it, and any OTHER interactive front-end for the exact same
  scaffold/task backend (create.init, create.wizard_tasks), consult ONE
  definition of "what a project can be" rather than two copies drifting
  apart. As of this file's creation the only other consumer is
  create/src/create/ui/typewriter_app.lua (a one-question-at-a-time
  prototype flow, opt-in via `hydronium-create --wizard --typewriter`) --
  see that file's own header comment for how it reuses this catalog.

  Nothing here owns any state (no signals) and nothing here talks to
  create.init/create.wizard_tasks/create.pm directly -- it is pure data
  and pure functions, safe to require from a Lab story, a test, or either
  wizard front-end without pulling in any I/O.
--]]

local M = {}

M.VERSION = "0.5.4"

-- Two subgroups: "Vite-based" frameworks always get the real Vite build
-- (create.vite -- package.json + vite.config.js, see that module's own
-- header comment) and CAN additionally turn Tailwind on as a purely
-- additive layer on top of it (create.tailwind); "No Vite" ones never get
-- either -- ink/love are LuaJIT-only terminal/game hosts with no browser
-- surface at all, and minimal is a bare embeddable component.
M.FRAMEWORKS = {
  { id = "ssr", label = "SSR", description = "Full-stack Meteorite app with browser Lua navigation", recommended = true, subgroup = "Vite-based" },
  { id = "spa", label = "SPA", description = "Client-only Ballad bundle, no server rendering", subgroup = "Vite-based" },
  { id = "islands", label = "Islands", description = "Server-rendered shell with JavaScript islands", subgroup = "Vite-based" },
  { id = "minimal", label = "Minimal", description = "One-shot component for scripts or embedding", subgroup = "No Vite" },
  { id = "ink", label = "Ink", description = "Interactive terminal UI, LuaJIT only", subgroup = "No Vite" },
  { id = "love", label = "LÖVE", description = "Game loop with topology-backed HMR, LuaJIT only", subgroup = "No Vite" },
}
M.ROUTED = { spa = true, islands = true }
-- Package manager: enabled for any Vite-based framework, independent of
-- Tailwind (see create/init.lua's own "Package manager: tied to VITE"
-- comment) -- Tailwind's own availability shares the exact same template
-- set, so one table serves both, kept as two names for readability at each
-- call site below.
M.VITE_SUPPORTED = { ssr = true, spa = true, islands = true }
M.TAILWIND_SUPPORTED = M.VITE_SUPPORTED
-- Mirrors template_specs[id].interpreters in create/src/create/init.lua:
-- ink/love are the only two templates that reject anything but LuaJIT.
M.INTERPRETER_LOCKED = { ink = true, love = true }

M.ROUTERS = {
  { id = "hydronium", label = "Hydronium Router", description = "Typed routes and client-side navigation", recommended = true },
  { id = "meteorite", label = "Meteorite only", description = "One server-declared route, no router manifest" },
}

-- Display order per the design spec's own "npm/pnpm/bun" -- independent of
-- create.pm's internal PREFERENCE order (pnpm/bun/npm) for auto-selecting
-- which one to actually run, which is a different concern.
M.PACKAGE_MANAGERS = { "npm", "pnpm", "bun" }

M.INTERPRETERS = {
  { id = "luajit@2.1", label = "LuaJIT 2.1", description = "FFI-based interpreter every template defaults to", recommended = true },
  { id = "lua@5.4", label = "Lua 5.4", description = "Reference PUC-Rio interpreter" },
}

M.MULTI_OPTION_FIELDS = { framework = true, router = true, package_manager = true, interpreter = true }

--- Finds `id` in a list of `{id=...}` entries (FRAMEWORKS/ROUTERS/
--- INTERPRETERS), or a plain string list (PACKAGE_MANAGERS).
function M.index_of_id(list, id, fallback)
  if id == nil then return fallback end
  for i, entry in ipairs(list) do
    if (type(entry) == "table" and entry.id == id) or entry == id then return i end
  end
  return fallback
end

function M.shallow_copy(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  return out
end

-- Project names become directory and package names: letters, digits, dot,
-- dash and underscore, starting with a letter or digit.
function M.name_problem(value)
  if value == "" then return "Project name cannot be empty" end
  if not value:match("^[%w][%w._-]*$") then return "Use letters, digits, . _ - (start with a letter or digit)" end
  return nil
end

function M.clip(value, columns)
  value = tostring(value or "")
  local chars = {}
  for ch in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  if #chars <= columns then return value end
  if columns < 2 then return "…" end
  return table.concat(chars, "", 1, columns - 1) .. "…"
end

return M
