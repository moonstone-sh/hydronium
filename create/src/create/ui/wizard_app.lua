-- Stepped inline setup shared by the CLI and Lab. Focus never changes a
-- selection; only explicit activation does. Review is the sole write boundary.
local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local signals = require("hydronium.signals")
local logo = require("create.ui.logo")
local fizzing = require("create.ui.fizzing")
local bubbles = require("create.ui.bubbles")
local checklist_ui = require("create.ui.checklist")
local oklab = require("hydronium_oklab_utils")

local M = {}

local VERSION = "0.5.3"

-- Two subgroups: "Vite-based" frameworks always get the real Vite build
-- (create.vite -- package.json + vite.config.js, see that module's own
-- header comment) and CAN additionally turn Tailwind on as a purely
-- additive layer on top of it (create.tailwind); "No Vite" ones never get
-- either -- ink/love are LuaJIT-only terminal/game hosts with no browser
-- surface at all, and minimal is a bare embeddable component.
local FRAMEWORKS = {
  { id = "ssr", label = "SSR", description = "Full-stack Meteorite app with browser Lua navigation", recommended = true, subgroup = "Vite-based" },
  { id = "spa", label = "SPA", description = "Client-only Ballad bundle, no server rendering", subgroup = "Vite-based" },
  { id = "islands", label = "Islands", description = "Server-rendered shell with JavaScript islands", subgroup = "Vite-based" },
  { id = "minimal", label = "Minimal", description = "One-shot component for scripts or embedding", subgroup = "No Vite" },
  { id = "ink", label = "Ink", description = "Interactive terminal UI, LuaJIT only", subgroup = "No Vite" },
  { id = "love", label = "LÖVE", description = "Game loop with topology-backed HMR, LuaJIT only", subgroup = "No Vite" },
}
local ROUTED = { spa = true, islands = true }
-- Package manager: enabled for any Vite-based framework, independent of
-- Tailwind (see create/init.lua's own "Package manager: tied to VITE"
-- comment) -- Tailwind's own availability shares the exact same template
-- set, so one table serves both, kept as two names for readability at each
-- call site below.
local VITE_SUPPORTED = { ssr = true, spa = true, islands = true }
local TAILWIND_SUPPORTED = VITE_SUPPORTED
-- Mirrors template_specs[id].interpreters in create/src/create/init.lua:
-- ink/love are the only two templates that reject anything but LuaJIT.
local INTERPRETER_LOCKED = { ink = true, love = true }

local ROUTERS = {
  { id = "hydronium", label = "Hydronium Router", description = "Typed routes and client-side navigation", recommended = true },
  { id = "meteorite", label = "Meteorite only", description = "One server-declared route, no router manifest" },
}

-- Display order per the design spec's own "npm/pnpm/bun" -- independent of
-- create.pm's internal PREFERENCE order (pnpm/bun/npm) for auto-selecting
-- which one to actually run, which is a different concern.
local PACKAGE_MANAGERS = { "npm", "pnpm", "bun" }

local INTERPRETERS = {
  { id = "luajit@2.1", label = "LuaJIT 2.1", description = "FFI-based interpreter every template defaults to", recommended = true },
  { id = "lua@5.4", label = "Lua 5.4", description = "Reference PUC-Rio interpreter" },
}

local MULTI_OPTION_FIELDS = { framework = true, router = true, package_manager = true, interpreter = true }

--- The flat, ordered list every navigation key actually walks -- one entry
--- per radio OPTION (not one per field), plus one entry each for the two
--- text fields, the three toggles, and the final submit node. `group`
--- indexes GROUP_TITLES (1-based). Continue/Back are shared page actions.
local STOPS = {}
do
  local function add(field_name, group, option_id)
    STOPS[#STOPS + 1] = { field = field_name, group = group, option_id = option_id }
  end
  add("name", 1)
  add("directory", 1)
  for _, f in ipairs(FRAMEWORKS) do add("framework", 2, f.id) end
  for _, r in ipairs(ROUTERS) do add("router", 3, r.id) end
  add("tailwind", 4)
  for _, name_candidate in ipairs(PACKAGE_MANAGERS) do add("package_manager", 5, name_candidate) end
  for _, it in ipairs(INTERPRETERS) do add("interpreter", 5, it.id) end
  add("install_deps", 5)
  add("git_init", 5)
  -- Review rows: Enter jumps to that step, and applying a change there
  -- returns here (see `returning` in create_wizard_app).
  for group = 1, 5 do add("edit", 6, group) end
  add("submit", 6)
  add("continue", 0)
  add("back", 0)
end
local GROUP_TITLES = { "Project", "App", "Flavour", "Features", "Tooling", "Review" }

--- Finds `id` in a list of `{id=...}` entries (FRAMEWORKS/ROUTERS/
--- INTERPRETERS), or a plain string list (PACKAGE_MANAGERS).
local function index_of_id(list, id, fallback)
  if id == nil then return fallback end
  for i, entry in ipairs(list) do
    if (type(entry) == "table" and entry.id == id) or entry == id then return i end
  end
  return fallback
end

local function shallow_copy(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  return out
end

-- Accent from the header's pH palette (its alkaline blue stop), lifted for
-- text legibility. The focus bar tints the REAL terminal background toward
-- it (hydronium_ink.terminal_background, detected once by the CLI) so it
-- stays subtle on light and dark themes alike; with no detected background
-- (Lab, piped, ansi16/none) the row keeps only its accent edge marker.
local ACCENT_OKLCH = oklab.oklch(0.72, 0.13, 250)
local ACCENT = ink.byProfile({ truecolor = ACCENT_OKLCH, ansi256 = ACCENT_OKLCH, ansi16 = "brightBlue" })
local function focus_colors(terminal_bg)
  if not terminal_bg then return { color = ACCENT } end
  local bar = oklab.ensure_contrast(oklab.mix(terminal_bg, oklab.oklch(0.60, 0.15, 250), 0.16), terminal_bg, 10)
  local text = oklab.ensure_contrast(ACCENT_OKLCH, bar, 60)
  return {
    color = ink.byProfile({ truecolor = text, ansi256 = text, ansi16 = "brightBlue" }),
    backgroundColor = ink.byProfile({ truecolor = bar, ansi256 = bar }),
  }
end

-- Project names become directory and package names: letters, digits, dot,
-- dash and underscore, starting with a letter or digit.
local function name_problem(value)
  if value == "" then return "Project name cannot be empty" end
  if not value:match("^[%w][%w._-]*$") then return "Use letters, digits, . _ - (start with a letter or digit)" end
  return nil
end
M.name_problem = name_problem

local function clip(value, columns)
  value = tostring(value or "")
  local chars = {}
  for ch in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  if #chars <= columns then return value end
  if columns < 2 then return "…" end
  return table.concat(chars, "", 1, columns - 1) .. "…"
end

function M.create_wizard_app(opts)
  opts = opts or {}
  local create_mod = opts.create_mod or require("create.init")
  local pm_mod = opts.pm_mod or require("create.pm")
  local wizard_tasks = opts.wizard_tasks_mod or require("create.wizard_tasks")
  local update_check_mod = opts.update_check_mod or require("create.update_check")
  -- `opts.update_status` lets a Lab story force a specific state. Otherwise
  -- the real check runs only when the caller opts in (`check_updates`, set by
  -- the CLI) -- Lab and tests never touch the cache or the network. Checked
  -- once per wizard, not per render; nil (unknown) renders no status.
  -- The live handle's poll() never blocks: it reports "checking" while a
  -- detached fetch runs, then settles; polled from render on the bubble tick.
  local update_handle
  if opts.update_status == nil and opts.check_updates then
    local ok, handle = pcall(update_check_mod.start, VERSION)
    update_handle = ok and handle or nil
  end
  local settled_status = opts.update_status
  local function update_status()
    if update_handle then
      local ok, status = pcall(update_handle.poll)
      status = ok and status or nil
      if not (status and status.state == "checking") then
        settled_status, update_handle = status, nil
      end
      return status
    end
    return settled_status
  end
  local dry_run = opts.dry_run
  if dry_run == nil then dry_run = true end -- Lab is always side-effect free.

  -- One reaction per run (`opts.reaction` pins it for stories and tests).
  local ascii = opts.ascii
  local reaction = opts.reaction or fizzing.pick(opts.seed)
  local reaction_timeline = fizzing.timeline(reaction, ascii)
  local focus_style = focus_colors(opts.terminal_background)
  local reduced_motion = opts.reduced_motion == true or os.getenv("HYDRONIUM_REDUCED_MOTION") == "1"
  -- Live "directory is not empty" hint, cached per path (it forks `ls`).
  -- Dry runs never write, so they never warn.
  local emptiness = {}
  local function directory_warning(dir)
    if dry_run or not create_mod.is_directory_empty then return nil end
    if emptiness[dir] == nil then emptiness[dir] = create_mod.is_directory_empty(dir) end
    if emptiness[dir] then return nil end
    return dir .. " is not empty: creating here needs --force"
  end

  return function()
    local exit = hooks.useApp().exit
    local terminal_rows = 24
    local managers = pm_mod.detect()
    local function detected(name)
      for _, m in ipairs(managers) do if m == name then return true end end
      return false
    end

    local name, setName = signals.createSignal(opts.name or "")
    -- `directory` follows "./<name>" live until the user edits it directly
    -- (see `directory_touched` below and the "name"/"directory" input
    -- handling further down) -- purely a WIZARD convenience for the
    -- common "type a name, get a new folder" flow. This is a deliberate
    -- divergence from hydronium-create's own plain, non-interactive CLI
    -- default: `create/src/main.lua`'s `target_dir = ctx.args.directory or
    -- "."` really does default to "." (scaffold IN the current directory)
    -- when no directory argument is given at all -- the wizard's live
    -- "./<name>" default is not a rediscovery of that default, it is a
    -- separate, better default for an interactive flow that already knows
    -- a name. An explicit `opts.directory` (a real --directory, or a
    -- story's own fixture) counts as already "touched" so it never gets
    -- silently overwritten by a later name edit.
    local directory_touched = opts.directory ~= nil
    local initial_directory = opts.directory
    if not initial_directory then
      initial_directory = (opts.name and opts.name ~= "") and ("./" .. opts.name) or "."
    end
    local directory, setDirectory = signals.createSignal(initial_directory)
    local name_error, setNameError = signals.createSignal(nil)
    local framework_index, setFrameworkIndex = signals.createSignal(index_of_id(FRAMEWORKS, opts.initial_framework_id, 1))
    local router_index, setRouterIndex = signals.createSignal(index_of_id(ROUTERS, opts.initial_router_id, 1))
    local tailwind, setTailwind = signals.createSignal(opts.initial_tailwind == true)
    local default_pm_index = 1
    for i, name_candidate in ipairs(PACKAGE_MANAGERS) do
      if detected(name_candidate) then default_pm_index = i break end
    end
    local pm_index, setPmIndex = signals.createSignal(index_of_id(PACKAGE_MANAGERS, opts.initial_package_manager_id, default_pm_index))
    local interpreter_index, setInterpreterIndex = signals.createSignal(INTERPRETER_LOCKED[FRAMEWORKS[framework_index()].id] and 1 or index_of_id(INTERPRETERS, opts.initial_interpreter_id, 1))
    local install_deps, setInstallDeps = signals.createSignal(opts.initial_install_deps ~= false)
    local git_init, setGitInit = signals.createSignal(opts.initial_git_init ~= false)
    local notice, setNotice = signals.createSignal(nil)
    local initial_page = 1
    for _, stop in ipairs(STOPS) do
      if stop.field == opts.initial_active_id then initial_page = stop.group; break end
    end
    if initial_page == 3 and not ROUTED[FRAMEWORKS[framework_index()].id] then initial_page = 4 end
    if initial_page == 4 and not TAILWIND_SUPPORTED[FRAMEWORKS[framework_index()].id] then initial_page = 5 end
    local page, setPage = signals.createSignal(initial_page)
    local scroll_revision, setScrollRevision = signals.createSignal(0)
    local scroll_delta, setScrollDelta = signals.createSignal(0)

    -- `initial_*` opts exist purely for create.stories.lua's isolated
    -- section/state snapshots -- `hydronium-create`'s real TTY path and
    -- the "install-flow" story never pass them, so the wizard always
    -- starts from its real defaults there. `initial_active_id` names a
    -- FIELD (not a raw stop index, which would be fragile to reorder);
    -- resolved to that field's first stop below.
    local function first_stop_of_field(field_name)
      for i, s in ipairs(STOPS) do if s.field == field_name then return i end end
      return 1
    end
    local initial_active = opts.initial_active_id and first_stop_of_field(opts.initial_active_id) or 1
    local initial_options = {framework = FRAMEWORKS[framework_index()].id, router = ROUTERS[router_index()].id,
      package_manager = PACKAGE_MANAGERS[pm_index()], interpreter = INTERPRETERS[interpreter_index()].id}
    for i, stop in ipairs(STOPS) do
      if stop.field == opts.initial_active_id and stop.option_id == initial_options[stop.field] then initial_active = i; break end
    end
    local active, writeActive = signals.createSignal(initial_active)
    local focus_revision, setFocusRevision = signals.createSignal(0)
    local function setActive(index)
      writeActive(index)
      setFocusRevision(focus_revision() + 1)
    end

    local preview = dry_run and opts.preview_phase ~= nil
    local phase, setPhase = signals.createSignal(preview and opts.preview_phase or "form") -- "form" | "tasks" | "done"
    local tasks, setTasks = signals.createSignal(preview and opts.preview_tasks or {})
    local scaffold_result, setScaffoldResult = signals.createSignal(preview and opts.preview_result or nil)
    local scaffold_error, setScaffoldError = signals.createSignal(nil)

    local task_anim = hooks.useAnimation({ interval = 120, isActive = true })

    local function framework_id() return FRAMEWORKS[framework_index()].id end

    --- Whether a given STOP can currently be landed on / selected.
    local function stop_enabled(stop)
      if stop.field == "edit" then
        if stop.option_id == 3 then return ROUTED[framework_id()] == true end
        if stop.option_id == 4 then return TAILWIND_SUPPORTED[framework_id()] == true end
        return true
      end
      if stop.field == "router" then return ROUTED[framework_id()] == true end
      if stop.field == "tailwind" then return TAILWIND_SUPPORTED[framework_id()] == true end
      if stop.field == "package_manager" then return VITE_SUPPORTED[framework_id()] == true end
      if stop.field == "interpreter" then
        if INTERPRETER_LOCKED[framework_id()] and stop.option_id ~= "luajit@2.1" then return false end
        return true
      end
      return true
    end

    --- The STOPS index of the option CURRENTLY selected for a multi-option
    --- field, or nil (never asked for a single-stop field). Landing on a
    --- field from an ADJACENT one always goes here first -- see this
    --- file's own header comment for why passing through a field must
    --- never reset its existing pick.
    local function selected_stop_index(field_name)
      for i, s in ipairs(STOPS) do
        if s.field == field_name then
          if field_name == "framework" and s.option_id == framework_id() then return i end
          if field_name == "router" and s.option_id == ROUTERS[router_index()].id then return i end
          if field_name == "package_manager" and s.option_id == PACKAGE_MANAGERS[pm_index()] then return i end
          if field_name == "interpreter" and s.option_id == INTERPRETERS[interpreter_index()].id then return i end
        end
      end
      return nil
    end

    --- Applies a concrete stop's option as that field's real selection.
    --- Also auto-corrects the interpreter when it lands on a
    --- LuaJIT-locked framework (ink/love) that would otherwise be left
    --- pointing at a now-invalid Lua 5.4 pick from an earlier framework.
    local function select_stop(stop)
      if stop.field == "framework" then
        setNotice(nil)
        setFrameworkIndex(index_of_id(FRAMEWORKS, stop.option_id, framework_index()))
        if INTERPRETER_LOCKED[stop.option_id] then
          if INTERPRETERS[interpreter_index()].id ~= "luajit@2.1" then
            setNotice("This template requires LuaJIT; interpreter adjusted.")
          end
          setInterpreterIndex(index_of_id(INTERPRETERS, "luajit@2.1", interpreter_index()))
        end
      elseif stop.field == "router" then
        setRouterIndex(index_of_id(ROUTERS, stop.option_id, router_index()))
      elseif stop.field == "package_manager" then
        setPmIndex(index_of_id(PACKAGE_MANAGERS, stop.option_id, pm_index()))
      elseif stop.field == "interpreter" then
        setInterpreterIndex(index_of_id(INTERPRETERS, stop.option_id, interpreter_index()))
      end
    end

    local function pages()
      local list = {1, 2}
      if ROUTED[framework_id()] then list[#list + 1] = 3 end
      if TAILWIND_SUPPORTED[framework_id()] then list[#list + 1] = 4 end
      list[#list + 1] = 5; list[#list + 1] = 6
      return list
    end
    local function visible_stops()
      local result = {}
      for i, stop in ipairs(STOPS) do
        if (stop.group == page() or (stop.field == "continue" and page() < 6)
          or (stop.field == "back" and page() > 1)) and stop_enabled(stop) then
          result[#result + 1] = i
        end
      end
      return result
    end
    local function jump_to_group(group)
      if group == 3 and not ROUTED[framework_id()] then group = 4 end
      if group == 4 and not TAILWIND_SUPPORTED[framework_id()] then group = 5 end
      setPage(group)
      -- Review opens on "Create project"; its edit rows sit above it.
      if group == 6 then setActive(first_stop_of_field("submit")); return end
      local choices = visible_stops()
      local index = choices[1]
      if index and MULTI_OPTION_FIELDS[STOPS[index].field] then
        index = selected_stop_index(STOPS[index].field) or index
      end
      setActive(index or first_stop_of_field("submit"))
    end
    local function move(delta, coarse)
      local choices = visible_stops()
      local position = 1
      for i, index in ipairs(choices) do if index == active() then position = i end end
      local previous_field = STOPS[active()].field
      for _ = 1, #choices do
        position = (position - 1 + delta) % #choices + 1
        local index = choices[position]
        if not coarse or STOPS[index].field ~= previous_field then
          if coarse and MULTI_OPTION_FIELDS[STOPS[index].field] then
            index = selected_stop_index(STOPS[index].field) or index
          end
          setActive(index)
          return
        end
      end
    end
    local function tab_move(delta) move(delta, true) end

    local function validate_name()
      local trimmed = name():match("^%s*(.-)%s*$")
      local problem = name_problem(trimmed)
      if problem then setNameError(problem); return false end
      setName(trimmed); setNameError(nil); return true
    end

    local function begin_submit()
      if phase() ~= "form" or page() ~= 6 then return end
      if not validate_name() then
        jump_to_group(1)
        return
      end
      local id = framework_id()
      local values = {
        directory = directory(), name = name(), template = id,
        force = opts.force, dry_run = dry_run, interpreter = INTERPRETERS[interpreter_index()].id,
      }
      if VITE_SUPPORTED[id] then
        values.tailwind = tailwind()
        values.package_manager = PACKAGE_MANAGERS[pm_index()]
      end
      if ROUTED[id] then values.router = ROUTERS[router_index()].id end

      local res, err = create_mod.scaffold(values)
      if not res then
        setScaffoldError(err)
        setTasks({ { id = "write", label = "Write project files", status = "error", error = err } })
        setPhase("tasks")
        if opts.onDone then opts.onDone(nil, err) end
        return
      end
      setScaffoldResult(res)
      local plan = wizard_tasks.plan({
        install_deps = install_deps(), vite = res.vite, git_init = git_init(),
        package_manager = res.package_manager,
      })
      plan[1] = { id = plan[1].id, label = plan[1].label, status = "done" } -- write already happened
      for i = 2, #plan do plan[i] = { id = plan[i].id, label = plan[i].label, status = "pending" } end
      setTasks(plan)
      setPhase("tasks")
      if #plan == 1 then
        setPhase("done")
        if opts.onDone then opts.onDone(res, nil) end
        if opts.auto_exit then exit() end
      end
    end

    -- Advances the task queue by (at most) one step per effect run --
    -- either promoting the next pending task to "running", or, if one is
    -- already "running", actually performing it and recording the result.
    -- See this file's header comment for the stated pacing limitation.
    hydronium.createEffect(function()
      if preview or phase() ~= "tasks" then return end
      task_anim.frame() -- subscribe: re-run on every tick while in this phase
      local list = tasks()
      for i, t in ipairs(list) do
        if t.status == "running" then
          local res = scaffold_result()
          local ok, err = wizard_tasks.run_task(t, {
            target_dir = res and res.target_dir or directory(),
            package_manager = res and res.package_manager,
            dry_run = dry_run,
            run_process = opts.run_process,
          })
          local copy = shallow_copy(list)
          copy[i] = { id = t.id, label = t.label, status = ok and "done" or "error", error = err }
          setTasks(copy)
          return
        elseif t.status == "pending" then
          local copy = shallow_copy(list)
          copy[i] = { id = t.id, label = t.label, status = "running" }
          setTasks(copy)
          return
        end
      end
      -- Every task is terminal (done or error). Only a SUCCESSFUL scaffold
      -- has a `scaffold_result()` to show next steps for -- the "scaffold
      -- itself failed" path above already left phase() == "tasks" with its
      -- one "error" task and no result, and must stay there (the render
      -- closure's `elseif scaffold_error()` branch is what shows that
      -- failure) rather than flip to "done" and crash indexing a nil result.
      if scaffold_result() then
        setPhase("done")
        if opts.onDone then opts.onDone(scaffold_result(), scaffold_error()) end
        if opts.auto_exit then exit() end
      end
    end)

    -- Editing from review: applying a change returns to the review row.
    local returning, setReturning = signals.createSignal(nil) -- the edit group, or nil
    local function back_to_review()
      local group = returning()
      setReturning(nil)
      setPage(6)
      for i, stop in ipairs(STOPS) do
        if stop.field == "edit" and stop.option_id == group then setActive(i); return end
      end
      setActive(first_stop_of_field("submit"))
    end

    local function change_page(delta)
      if returning() then
        if delta > 0 and page() == 1 and not validate_name() then return end
        back_to_review(); return
      end
      if delta > 0 and page() == 1 and not validate_name() then
        setActive(first_stop_of_field("name")); return
      end
      local list = pages()
      for i, number in ipairs(list) do
        if number == page() then jump_to_group(list[math.max(1, math.min(#list, i + delta))]); return end
      end
    end

    -- Enter applies and moves on (or returns to review); Space applies in place.
    local function after_apply()
      if returning() then
        if page() == 1 and not validate_name() then return end
        back_to_review()
      else
        tab_move(1)
      end
    end

    -- The header's intro clock. A key press finishes the reveal instantly
    -- (the key still reaches the form); `intro = false` hosts start settled.
    local intro_offset, setIntroOffset = signals.createSignal(
      (reduced_motion or opts.intro == false) and fizzing.final_time(reaction, ascii) or 0)
    local header_clock = 0
    local function skip_intro()
      if header_clock + intro_offset() < reaction_timeline.faded_at then
        setIntroOffset(reaction_timeline.faded_at - header_clock)
      end
    end

    hooks.useInput(function(input, key)
      if phase() ~= "form" then
        if phase() == "done" or scaffold_error() then exit() end
        return
      end
      skip_intro()
      if key.escape then
        if returning() then back_to_review() else change_page(-1) end
        return
      end
      if key.pageUp or key.pageDown then
        -- A wheel/Lab scroll names its rows; a Page key moves a page.
        setScrollDelta((key.pageUp and -1 or 1) * (key.scrollRows or math.max(terminal_rows - 4, 1)))
        setScrollRevision(scroll_revision() + 1); return
      end
      -- Shortcuts open review; they never bypass explicit acceptance.
      if (key["return"] and key.ctrl) or (input == "s" and key.ctrl) then
        setReturning(nil)
        if validate_name() then jump_to_group(6) else jump_to_group(1) end
        return
      end
      if key.tab then tab_move(key.shift and -1 or 1); return end
      if key.upArrow then move(-1); return end
      if key.downArrow then move(1); return end
      local stop = STOPS[active()]
      local text_input = stop.field == "name" or stop.field == "directory"
      if not text_input and (input == "j" or input == "k") then move(input == "j" and 1 or -1); return end
      if not text_input and not returning() and input:match("^[1-6]$") then
        local target = pages()[tonumber(input)]
        if target then jump_to_group(target) end
        return
      end
      local enter, space = key["return"], input == " " and not text_input
      if enter or space then
        if stop.field == "continue" then change_page(1)
        elseif stop.field == "back" then change_page(-1)
        elseif stop.field == "submit" then begin_submit()
        elseif stop.field == "edit" then
          setReturning(stop.option_id)
          setPage(stop.option_id)
          local choices = visible_stops()
          local index = choices[1]
          if index and MULTI_OPTION_FIELDS[STOPS[index].field] then index = selected_stop_index(STOPS[index].field) or index end
          setActive(index or first_stop_of_field("submit"))
        else
          if MULTI_OPTION_FIELDS[stop.field] then select_stop(stop)
          elseif stop.field == "tailwind" then setTailwind(not tailwind())
          elseif stop.field == "install_deps" then setInstallDeps(not install_deps())
          elseif stop.field == "git_init" then setGitInit(not git_init()) end
          if enter then after_apply() end
        end
        return
      end
      if stop.field == "name" then
        if key.backspace or key.delete then setName(name():sub(1, -2))
        elseif input ~= "" and not key.ctrl then setName(name() .. input) end
        if name_error() and not name_problem(name()) then setNameError(nil) end
        if not directory_touched then setDirectory(name() == "" and "." or ("./" .. name())) end
      elseif stop.field == "directory" then
        directory_touched = true
        if key.backspace or key.delete then setDirectory(directory():sub(1, -2))
        elseif input ~= "" and not key.ctrl then setDirectory(directory() .. input) end
      end
    end)

    -- Header, top to bottom:
    --   brand line   "hydronium/create vX.Y.Z" left; update status right, its
    --                badge always the rightmost cell
    --   bubble band  4 rows; the reaction centered on its third row, so the
    --                fizz has two rows of ceiling
    -- Rows it takes, by terminal size:
    --   6  brand + band + spacer               rows >= 24 and the reaction fits
    --   3  brand + centered reaction + spacer  rows >= 20
    --   1  brand only
    local REACTION_WIDTH = fizzing.width(ascii)
    local BRAND = "hydronium/create v" .. VERSION
    local function header_height(columns, rows)
      local inner = columns - 2
      if rows >= 24 and inner >= REACTION_WIDTH + 2 then return 6 end
      if rows >= 20 then return 3 end
      return 1
    end

    -- The status keeps its badge; the brand and the label share what is
    -- left, preferring the full brand, then the fuller label.
    local function brand_row(columns, status, clock)
      local brand, tier = "hydronium/create", 0
      for _, candidate in ipairs({ { BRAND, 80 }, { BRAND, 64 }, { BRAND, 0 }, { "hydronium/create", 0 }, { "create", 0 } }) do
        if columns >= #candidate[1] + 1 + logo.status_width(status, candidate[2]) then
          brand, tier = candidate[1], candidate[2]
          break
        end
      end
      return hydronium.h(ink.Box, { flexDirection = "row", width = columns },
        hydronium.h(ink.Text, { color = "brightBlack" }, brand),
        hydronium.h(ink.Spacer, {}),
        logo.render_status(status, tier, math.floor(clock / 100)))
    end

    local function reaction_row(columns, t)
      local compact = columns < REACTION_WIDTH
      return hydronium.h(ink.Box, { flexDirection = "row", width = columns, justifyContent = "center" },
        fizzing.render({ index = reaction, time = t, ascii = ascii, compact = compact }))
    end

    -- Two clocks: a fast one while characters reveal (one per ~frame), then
    -- the ambient 100ms one for the fizz. The idle clock starts where the
    -- fast one left off, so time never jumps backwards.
    local fast_phase, setFastPhase = signals.createSignal(not reduced_motion and opts.intro ~= false)
    local handoff_at = 0
    local function HeaderFrame(props)
      local anim = hooks.useAnimation({ interval = props.interval, isActive = true })
      if props.interval < 100 then
        hydronium.createEffect(function()
          local t = props.base + anim.time() + intro_offset()
          if t >= reaction_timeline.faded_at then
            handoff_at = props.base + anim.time()
            setFastPhase(false)
          end
        end)
      end
      return function()
        local size = hooks.useWindowSize()
        local columns, rows = (size.columns or 80) - 2, size.rows or 24
        local clock = props.base + anim.time()
        header_clock = clock
        local t = reduced_motion and fizzing.final_time(reaction, ascii) or (clock + intro_offset())
        local brand = brand_row(columns, update_status(), clock)
        local height = header_height(columns + 2, rows)
        if height == 1 then return brand end
        local reaction_el = reaction_row(columns, t)
        local body = height == 6 and bubbles.render_diorama({
          time = t, columns = columns, still = reduced_motion,
          start = reaction_timeline.lit_at, burst_ms = fizzing.BURST_MS,
        }, reaction_el) or reaction_el
        return hydronium.h(ink.Box, { flexDirection = "column" }, brand, body, hydronium.h(ink.Newline, {}))
      end
    end
    local function Header()
      return function()
        if fast_phase() then return hydronium.h(HeaderFrame, { key = "intro", interval = 30, base = 0 }) end
        return hydronium.h(HeaderFrame, { key = "idle", interval = 100, base = handoff_at })
      end
    end

    local RADIO_ON, RADIO_OFF = "● ", "○ "
    local BOX_ON, BOX_OFF = "■ ", "□ "
    local HEADINGS = { "Project", "App", "Router", "Tailwind", "Tooling" }

    local function tooling_summary()
      local parts = {}
      if VITE_SUPPORTED[framework_id()] then parts[#parts + 1] = PACKAGE_MANAGERS[pm_index()] end
      parts[#parts + 1] = INTERPRETERS[interpreter_index()].label
      parts[#parts + 1] = install_deps() and "install deps" or "no install"
      parts[#parts + 1] = git_init() and "git" or "no git"
      return table.concat(parts, " · ")
    end
    local function review_value(group)
      if group == 1 then return name() .. "  " .. directory() end
      if group == 2 then return FRAMEWORKS[framework_index()].label end
      if group == 3 then return ROUTERS[router_index()].label end
      if group == 4 then return tailwind() and "on" or "off" end
      return tooling_summary()
    end
    local function one_line_summary()
      local parts = { FRAMEWORKS[framework_index()].label }
      if ROUTED[framework_id()] then parts[#parts + 1] = ROUTERS[router_index()].label end
      if VITE_SUPPORTED[framework_id()] and tailwind() then parts[#parts + 1] = "Tailwind" end
      parts[#parts + 1] = tooling_summary()
      return table.concat(parts, " · ") .. "  →  " .. directory()
    end

    return function()
      local size = hooks.useWindowSize()
      local columns = size.columns or 80
      terminal_rows = size.rows or 24
      local form = phase() == "form"
      local inner = columns - 2
      local lines = {}
      local function line(text, props)
        props = props or {}; props.key = #lines + 1
        lines[#lines + 1] = hydronium.h(ink.Text, props, form and clip(text, inner) or text)
      end
      if form then
        local list, ordinal = pages(), 1
        for i, number in ipairs(list) do if number == page() then ordinal = i end end
        line(string.format("%d/%d  %s", ordinal, #list, GROUP_TITLES[page()]), { bold = true, color = ACCENT })
        local focused = STOPS[active()]
        local visible = visible_stops()
        local heading_rows = header_height(columns, terminal_rows)
        local room = math.max(3, terminal_rows - heading_rows - 7)
        local position = 1
        for i, index in ipairs(visible) do if index == active() then position = i end end
        local first = math.max(1, math.min(position - room + 1, #visible - room + 1))
        for item = first, math.min(#visible, first + room - 1) do
          local index = visible[item]
          local stop = STOPS[index]
          local focus = index == active()
          local label
          -- An empty name shows a dim placeholder after the cursor, never
          -- text that looks already typed.
          local placeholder
          if stop.field == "name" then
            label = "name       " .. name() .. (focus and "▍" or "")
            if name() == "" then placeholder = "my-app" end
          elseif stop.field == "directory" then label = "directory  " .. directory() .. (focus and "▍" or "")
          elseif MULTI_OPTION_FIELDS[stop.field] then
            local options = stop.field == "framework" and FRAMEWORKS or stop.field == "router" and ROUTERS
              or stop.field == "interpreter" and INTERPRETERS or PACKAGE_MANAGERS
            local option = options[index_of_id(options, stop.option_id, 1)]
            label = (selected_stop_index(stop.field) == index and RADIO_ON or RADIO_OFF)
              .. (type(option) == "table" and option.label or option)
            if stop.field == "package_manager" and not detected(stop.option_id) then label = label .. "  (not installed)" end
          elseif stop.field == "tailwind" then label = (tailwind() and BOX_ON or BOX_OFF) .. "Tailwind CSS"
          elseif stop.field == "install_deps" then label = (install_deps() and BOX_ON or BOX_OFF) .. "Install dependencies"
          elseif stop.field == "git_init" then label = (git_init() and BOX_ON or BOX_OFF) .. "Initialize Git"
          elseif stop.field == "edit" then label = string.format("%-9s %s", HEADINGS[stop.option_id], review_value(stop.option_id))
          elseif stop.field == "continue" then label = returning() and "Back to review" or "Continue →"
          elseif stop.field == "back" then label = returning() and "← Review" or "← Back"
          elseif stop.field == "submit" then label = "Create project" end
          local text = (focus and "▌ " or "  ") .. label
          local function cells(value)
            local n = 0
            for _ in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
            return n
          end
          if placeholder then
            -- Label, dim placeholder, then padding: separate segments so the
            -- placeholder keeps its own style inside the focus bar.
            local bar = focus and focus_style.backgroundColor or nil
            local parts = { hydronium.h(ink.Text, { key = "text", bold = focus, color = focus and focus_style.color or nil,
              backgroundColor = bar, scrollFocus = focus }, text) }
            parts[#parts + 1] = hydronium.h(ink.Text, { key = "placeholder", color = "brightBlack", dimColor = true, backgroundColor = bar }, placeholder)
            local used = cells(text) + cells(placeholder)
            if focus and used < inner then
              parts[#parts + 1] = hydronium.h(ink.Text, { key = "pad", backgroundColor = bar }, string.rep(" ", inner - used))
            end
            lines[#lines + 1] = hydronium.h(ink.Box, { key = #lines + 1, flexDirection = "row" }, parts)
          elseif focus then
            -- Full-width so the focus bar spans the row.
            local width = cells(text)
            if width < inner then text = text .. string.rep(" ", inner - width) end
            line(text, { bold = true, color = focus_style.color, backgroundColor = focus_style.backgroundColor, scrollFocus = true })
          else
            line(text, { dimColor = stop.field == "edit" and false or nil })
          end
        end
        if page() == 1 then
          local problem = name_error() or (name() ~= "" and name_problem(name()))
          if problem then line("  " .. problem, { color = "yellow" }) end
          local warning = directory_warning(directory())
          if warning then line("  " .. warning, { color = "yellow" }) end
        end
        if notice() and page() == 2 then line("  " .. notice(), { color = "yellow" }) end
        if terminal_rows >= 24 then
          local options = focused.field == "framework" and FRAMEWORKS or focused.field == "router" and ROUTERS
            or focused.field == "interpreter" and INTERPRETERS
          if options then line("  " .. options[index_of_id(options, focused.option_id, 1)].description, { dimColor = true }) end
        end
        -- Two stable footer rows across pages and focus changes.
        while #lines < terminal_rows - 2 - heading_rows - 2 do line("") end
        line((name() == "" and "new project" or name()) .. " · " .. one_line_summary(), { dimColor = true })
        local hint
        if returning() then
          hint = "Enter apply & return · Space pick · Esc back to review"
        elseif columns >= 76 then
          hint = "↑↓ move · Space pick · Enter pick & next · Tab field · Esc back · 1–" .. #list .. " steps"
        else
          hint = "↑↓ · Space pick · Enter next · Esc back"
        end
        line(hint, { dimColor = true })
      else
        local done = phase() == "done"
        local failed = false
        for _, task in ipairs(tasks()) do if task.status == "error" then failed = true end end
        if done then
          local res = scaffold_result()
          line((failed and "Created " or "✔ Created ") .. name() .. (res and res.dry_run and "  (dry run)" or ""),
            { bold = true, color = failed and "yellow" or "green" })
        else
          line("Creating " .. name(), { bold = true, color = ACCENT })
        end
        line("  " .. one_line_summary(), { dimColor = true })
        lines[#lines + 1] = checklist_ui.render(tasks(), phase() == "tasks" and task_anim.frame() or 0)
        if scaffold_error() then line(tostring(scaffold_error()), { color = "red" }) end
        if done then
          local res = scaffold_result()
          if failed then line("Files were created; the steps marked ✖ need attention.", { color = "yellow" }) end
          line("")
          line("Next steps", { bold = true })
          if res.target_dir and res.target_dir ~= "." then line("  cd " .. string.format("%q", res.target_dir), { color = ACCENT }) end
          if not install_deps() then
            line("  moon sync", { color = ACCENT })
            if res.vite then line("  " .. (res.package_manager or PACKAGE_MANAGERS[pm_index()]) .. " install", { color = ACCENT }) end
          end
          line("  moon run " .. tostring(res.next_script), { color = ACCENT })
        end
      end
      return hydronium.h(ink.Box, {flexDirection = "column", paddingX = 1, inlineViewport = true,
        scrollRevision = scroll_revision(), scrollDelta = scroll_delta(), focusRevision = focus_revision()},
        form and hydronium.h(Header, {key = "fizzing"}) or nil,
        hydronium.h(ink.Box, {flexDirection = "column"}, lines))
    end
  end
end

return M
