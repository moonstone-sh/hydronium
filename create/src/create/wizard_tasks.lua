--[[
  hydronium_create.wizard_tasks -- the post-submit checklist's real work:
  write files (already done by create.scaffold before this module ever
  runs), `moon sync`, the JS package manager install (whenever the
  scaffolded template is Vite-based -- ssr/spa/islands, see create.vite --
  and "install dependencies now" is on; NOT gated on Tailwind, which is a
  purely additive layer on top of the same Vite base, see
  create/tailwind.lua's own header comment), and `git init` -- each one only
  present at all when the wizard's own toggle for it was on, and each one a
  REAL operation, never a faked delay, except under `dry_run` (Ink Lab and
  its stories, which must never touch disk or spawn a process -- see
  create.ui.wizard_app's own "dry_run defaults true" comment) where every
  task after "write files" reports success immediately with no side effect
  at all.

  Uses create.process (the same quoted, platform-aware command builder
  process_spec.lua/create_spec.lua already cover) rather than a bespoke
  os.execute call, so this gets the same POSIX-quoting/Windows-cmd-
  metacharacter-rejection guarantees the rest of this package already
  relies on.
]]

local process = require("create.process")
local pm = require("create.pm")

local M = {}

--- The task list a given wizard selection WOULD run -- always fully
--- populated regardless of dry_run, so the checklist shows the real plan
--- even in a Lab preview that never executes any of it.
--- @param opts { install_deps: boolean, vite: boolean, package_manager: string?, git_init: boolean }
--- @return { id: string, label: string }[]
function M.plan(opts)
  opts = opts or {}
  local tasks = { { id = "write", label = "Write project files" } }
  if opts.install_deps then
    tasks[#tasks + 1] = { id = "sync", label = "moon sync" }
    if opts.vite then
      tasks[#tasks + 1] = { id = "js_install", label = (opts.package_manager or "npm") .. " install" }
    end
  end
  if opts.git_init then
    tasks[#tasks + 1] = { id = "git", label = "git init" }
  end
  return tasks
end

--- Runs one task from `plan()`. `target_dir` is the real (or, under
--- dry_run, would-be) project directory. Returns `true`, or `false, err`.
--- @param task { id: string }
--- @param ctx { target_dir: string, package_manager: string?, dry_run: boolean, run_process: function?, pm_mod: table? }
--- @return boolean ok, string? err
function M.run_task(task, ctx)
  if ctx.dry_run then return true end
  local run_process = ctx.run_process or process.run

  if task.id == "write" then
    -- Already performed by create.scaffold before wizard_app ever calls
    -- into this module -- listed here purely so the checklist shows it as
    -- the first completed step.
    return true
  elseif task.id == "sync" then
    local res = run_process({ tool = "moon", cwd = ctx.target_dir, args = { "sync" } })
    if res.exit_code ~= 0 then return false, "moon sync failed: " .. tostring(res.stderr ~= "" and res.stderr or res.command) end
    return true
  elseif task.id == "js_install" then
    local pm_mod = ctx.pm_mod or pm
    local manager = ctx.package_manager or "npm"
    -- Only this task actually requires the resolved package manager to
    -- exist on PATH -- create.scaffold itself never refuses for lack of
    -- one (files are written regardless, like `npm create vite`). Fail
    -- with a clear, actionable hint here instead of a generic "command not
    -- found" shell error from run_process.
    local available = false
    for _, name in ipairs(pm_mod.detect()) do
      if name == manager then available = true break end
    end
    if not available then
      return false, string.format(
        "%s was not found on PATH -- install npm, pnpm, or bun, then run `%s` yourself in %s.",
        manager, pm_mod.install_command(manager), ctx.target_dir)
    end
    local install = pm_mod.install_command(manager)
    local tool, arg = install:match("^(%S+)%s*(.*)$")
    local args = {}
    if arg and arg ~= "" then for word in arg:gmatch("%S+") do args[#args + 1] = word end end
    local res = run_process({ tool = tool, cwd = ctx.target_dir, args = args })
    if res.exit_code ~= 0 then return false, manager .. " install failed: " .. tostring(res.stderr ~= "" and res.stderr or res.command) end
    return true
  elseif task.id == "git" then
    local res = run_process({ tool = "git", cwd = ctx.target_dir, args = { "init" } })
    if res.exit_code ~= 0 then return false, "git init failed: " .. tostring(res.stderr ~= "" and res.stderr or res.command) end
    return true
  end
  return false, "unknown task '" .. tostring(task.id) .. "'"
end

return M
