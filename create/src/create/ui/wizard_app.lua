--[[
  hydronium_create.ui.wizard_app -- the persistent, always-visible Ink form
  used by both `hydronium-create`'s real TTY path (src/main.lua) and the
  Lab "install-flow" story (create.stories.lua). One component, two hosts.

  DESIGN, from the 20-question interview this implements faithfully:
    - inline form in scrollback, never the alternate screen -- the whole
      form is always rendered, and stays readable once scrolled back. No
      separate "review" step: what you see while filling it in IS the
      final record of what will be created.
    - a left RAIL ("|") joins the four groups (Project/Stack/Styling/
      Tooling); each group's own line gets "◆" while it holds the
      currently active field, "◇" otherwise, and inactive groups render
      dimmed. A blank rail line pads the start and end of every group's
      content (see ui/field.lua's own header for the "option/description/
      blank" rhythm inside a group).
    - a final rail node closes the form: "◆ ▐ Create <name> ▌ ↵".
    - every alternative is always visible; radios (◉/◇) are single-choice,
      toggles (▣/□) are yes/no. A recommended option gets " ★". An
      alternative that is NOT the current pick renders struck through+dim
      UNLESS its field is the one currently focused (see ui/field.lua).
      The framework radio list also has two SUBGROUPS ("Vite-based":
      SSR/SPA/Islands, which can turn on Tailwind's Vite side-build; "No
      Vite": Minimal/Ink/LÖVE, which never can) -- see ui/field.lua's
      subgroup-header support.
    - navigation is STOP-based, not field-based: every individual radio
      OPTION (not just its owning field) is its own addressable stop, in
      the same visual order they're stacked on screen. ↑/↓ (and, for a
      radio field, ←/→ too -- see below) walk that flat list one stop at
      a time: while the cursor is already inside a multi-option field it
      moves among THAT field's own options (matching their vertical
      stacking -- picking sideways through a vertically drawn list read
      as backwards, which is why ←/→ mirror ↑/↓ here rather than doing
      something unrelated), and once you walk off either end it rolls
      into the ADJACENT field, landing on whatever that field's own
      CURRENT selection already is (never resetting it to that field's
      first option just because you passed through). Space still flips a
      toggle; ←/→ do too, for the same reason a physical switch reads as
      a left/right (or on/off) gesture rather than an up/down one.
      Tab/Shift+Tab are the COARSE alternative: they always land on the
      next/previous FIELD's current selection, skipping over every option
      in between in one hop. Digits 1-4 jump to a section's current stop
      (only when the focused field isn't free-text, so a name/directory
      containing a digit still types normally -- see `is_text_field`
      below). Enter submits from the final rail node or otherwise just
      advances, like Tab. Ctrl+Enter submits from anywhere a real
      terminal can tell Ctrl+Enter apart from plain Enter (a
      Kitty-protocol CSI u sequence -- see hydronium_ink's keys.lua), and
      Ctrl+S is the documented, always-distinguishable fallback (shown in
      the footer) for terminals that can't.
    - the H3O+ header, gradient, and rising bubbles are ui/logo.lua and
      ui/bubbles.lua (both pure `render(props)`, easy to snapshot in
      isolation -- see create.stories.lua).
    - after submit the form FREEZES (it just stops responding to
      picking/typing -- every value stays on screen exactly as chosen) and
      a live checklist (ui/checklist.lua, driven by create.wizard_tasks)
      appears below it, with a "Protonating <name>..." status pun while it
      runs, followed by next steps and a closing gradient rule.

  Collection stays in create.init.scaffold; this file's only side effects
  are the real (or, under dry_run, no-op) tasks create.wizard_tasks runs
  after a successful scaffold -- see that module's own header for exactly
  what "real" means here and its one stated limitation (task progress is
  only as granular as this synchronous event loop allows -- there is no
  coroutine-based process execution in this codebase yet, so a slow task
  can render as a silent pause rather than a smoothly animating spinner;
  the pause itself is honest, not faked).

  Why there is no separate "use LUAX?" toggle: LUAX is entirely a
  CONSEQUENCE of the framework choice, never an independent axis --
  create/src/create/init.lua's own `template_specs[id].tooling.luax` is
  true for ssr/islands/ink (they generate `.luax` views/UI) and false for
  spa/minimal/love (plain `.lua`, no LUAX compile step at all). Exposing
  it as a second, independently-toggleable control would let someone pick
  a combination create.scaffold has no wiring for. Each framework option's
  own description already says what it generates; that is the only place
  this needs to be visible.
--]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local signals = require("hydronium.signals")
local field = require("create.ui.field")
local logo = require("create.ui.logo")
local bubbles = require("create.ui.bubbles")
local checklist_ui = require("create.ui.checklist")

local M = {}

local VERSION = "0.5.0"

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
--- indexes GROUP_TITLES (1-based); "submit" has no group of its own -- it
--- is the final rail node. See this file's own header comment for why
--- navigation is stop-based rather than field-based.
local STOPS = {}
do
  local function add(field_name, group, option_id)
    STOPS[#STOPS + 1] = { field = field_name, group = group, option_id = option_id }
  end
  add("name", 1)
  add("directory", 1)
  for _, f in ipairs(FRAMEWORKS) do add("framework", 2, f.id) end
  for _, r in ipairs(ROUTERS) do add("router", 2, r.id) end
  add("tailwind", 3)
  for _, name_candidate in ipairs(PACKAGE_MANAGERS) do add("package_manager", 4, name_candidate) end
  for _, it in ipairs(INTERPRETERS) do add("interpreter", 4, it.id) end
  add("install_deps", 4)
  add("git_init", 4)
  add("submit", 5)
end
local GROUP_TITLES = { "Project", "Stack", "Styling", "Tooling" }

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

local function clip(value, columns)
  value = tostring(value or "")
  if #value <= columns then return value end
  if columns < 2 then return "…" end
  return value:sub(1, columns - 1) .. "…"
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

  return function()
    local exit = hooks.useApp().exit
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
    local interpreter_index, setInterpreterIndex = signals.createSignal(index_of_id(INTERPRETERS, opts.initial_interpreter_id, 1))
    local install_deps, setInstallDeps = signals.createSignal(opts.initial_install_deps ~= false)
    local git_init, setGitInit = signals.createSignal(opts.initial_git_init ~= false)
    local cheat, setCheat = signals.createSignal(opts.initial_cheat == true)

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
    local active, setActive = signals.createSignal(opts.initial_active_id and first_stop_of_field(opts.initial_active_id) or 1)

    local phase, setPhase = signals.createSignal("form") -- "form" | "tasks" | "done"
    local tasks, setTasks = signals.createSignal({})
    local scaffold_result, setScaffoldResult = signals.createSignal(nil)
    local scaffold_error, setScaffoldError = signals.createSignal(nil)

    -- One-time startup gradient sweep across the header (skippable by any
    -- key). Independent of the bubble ticker below -- the sweep is a short,
    -- one-shot cue; bubbles keep animating for as long as the form is open.
    -- A real signal, not a plain Lua local: `setSweeping(false)` on any
    -- keypress must be an actual signal write so the render closure (which
    -- reads `sweeping()` reactively) repaints IMMEDIATELY, in the same
    -- dispatch -- not only whenever the next bubble/task tick happens to
    -- land. A mutated plain local would sit unseen until some OTHER signal
    -- changed, since Session:dispatch never force-renders independent of
    -- what a component's own reactive reads actually depend on.
    local sweeping, setSweeping = signals.createSignal(opts.intro == true)
    local SWEEP_MS = 700
    -- Header animation time as last rendered (a plain value, written by the
    -- Header component's render): lets the key handler tell whether the
    -- sweep is still showing without subscribing anything to the ticker.
    local header_time_ms = 0
    -- Task checklist spinner + one-task-per-tick pacing (see this file's
    -- own header comment for the stated limitation on how granular that
    -- pacing actually is without a coroutine-based process runner).
    local task_anim = hooks.useAnimation({ interval = 120, isActive = true })

    local function framework_id() return FRAMEWORKS[framework_index()].id end

    --- Whether a given STOP can currently be landed on / selected.
    local function stop_enabled(stop)
      if stop.field == "router" then return ROUTED[framework_id()] == true end
      if stop.field == "tailwind" then return TAILWIND_SUPPORTED[framework_id()] == true end
      if stop.field == "package_manager" then return VITE_SUPPORTED[framework_id()] == true and detected(stop.option_id) end
      if stop.field == "interpreter" then
        if INTERPRETER_LOCKED[framework_id()] and stop.option_id ~= "luajit@2.1" then return false end
        return true
      end
      return true
    end

    --- Whether a whole FIELD (not a specific option) currently applies --
    --- used by the render loop for hint/disabled-reason text, not by
    --- navigation itself (which only ever asks stop_enabled about one
    --- concrete stop at a time).
    local function field_enabled(field_name)
      if field_name == "router" then return ROUTED[framework_id()] == true end
      if field_name == "tailwind" then return TAILWIND_SUPPORTED[framework_id()] == true end
      if field_name == "package_manager" then return VITE_SUPPORTED[framework_id()] == true end
      return true
    end

    local function router_disabled_reason()
      if framework_id() == "ssr" then return "SSR always uses Hydronium Router" end
      if ROUTED[framework_id()] then return nil end
      return "Only configurable for SPA/Islands"
    end
    -- Tailwind is enabled for any Vite-based framework regardless of
    -- whether a JS package manager was actually detected -- like the
    -- package manager field itself, missing PATH tooling shows up as a
    -- field-level NOTE there (see the package-manager render block below),
    -- never as a reason this toggle itself is unreachable.
    local function tailwind_disabled_reason()
      if not TAILWIND_SUPPORTED[framework_id()] then
        return "Not supported for " .. FRAMEWORKS[framework_index()].label .. " projects"
      end
      return nil
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
        setFrameworkIndex(index_of_id(FRAMEWORKS, stop.option_id, framework_index()))
        if INTERPRETER_LOCKED[stop.option_id] then
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

    --- Fine-grained move (↑/↓ always; ←/→ too, while parked on a
    --- multi-option field -- see this file's own header comment). Tries
    --- stepping within the CURRENT field's own options first; once that
    --- runs out, rolls into the next enabled field in that direction and
    --- lands on ITS current selection rather than resetting it.
    local function move(delta)
      local cur = STOPS[active()]
      if MULTI_OPTION_FIELDS[cur.field] then
        local try = active()
        local guard = 0
        repeat
          try = try + delta
          guard = guard + 1
        until try < 1 or try > #STOPS or STOPS[try].field ~= cur.field or stop_enabled(STOPS[try]) or guard > #STOPS
        if try >= 1 and try <= #STOPS and STOPS[try].field == cur.field and stop_enabled(STOPS[try]) then
          setActive(try)
          select_stop(STOPS[try])
          return
        end
      end

      local index = active()
      local guard = 0
      repeat
        index = index + delta
        if index < 1 then index = #STOPS end
        if index > #STOPS then index = 1 end
        guard = guard + 1
      until (STOPS[index].field ~= cur.field and stop_enabled(STOPS[index])) or guard > #STOPS
      local landed_field = STOPS[index].field
      if MULTI_OPTION_FIELDS[landed_field] then
        local sel = selected_stop_index(landed_field)
        if sel and stop_enabled(STOPS[sel]) then index = sel end
      end
      setActive(index)
    end

    --- Coarse move (Tab/Shift+Tab, and Enter as a Tab-alias): always jumps
    --- past every option of the current field to the next/previous
    --- DIFFERENT field's own current selection.
    local function tab_move(delta)
      local cur_field = STOPS[active()].field
      local index = active()
      local guard = 0
      repeat
        index = index + delta
        if index < 1 then index = #STOPS end
        if index > #STOPS then index = 1 end
        guard = guard + 1
      until (STOPS[index].field ~= cur_field and stop_enabled(STOPS[index])) or guard > #STOPS
      local landed_field = STOPS[index].field
      if MULTI_OPTION_FIELDS[landed_field] then
        local sel = selected_stop_index(landed_field)
        if sel and stop_enabled(STOPS[sel]) then index = sel end
      end
      setActive(index)
    end

    local function jump_to_group(group_number)
      local start = nil
      for i, s in ipairs(STOPS) do if s.group == group_number then start = i break end end
      if not start then return end
      for i = start, #STOPS do
        if stop_enabled(STOPS[i]) then
          local f = STOPS[i].field
          if MULTI_OPTION_FIELDS[f] then
            local sel = selected_stop_index(f)
            setActive(sel and stop_enabled(STOPS[sel]) and sel or i)
          else
            setActive(i)
          end
          return
        end
      end
      setActive(start)
    end

    local function validate_name()
      local trimmed = name():match("^%s*(.-)%s*$")
      if trimmed == "" then setNameError("Project name cannot be empty"); return false end
      setName(trimmed); setNameError(nil); return true
    end

    local function begin_submit()
      if phase() ~= "form" then return end
      if not validate_name() then
        setActive(first_stop_of_field("name"))
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
      end
    end

    -- Advances the task queue by (at most) one step per effect run --
    -- either promoting the next pending task to "running", or, if one is
    -- already "running", actually performing it and recording the result.
    -- See this file's header comment for the stated pacing limitation.
    hydronium.createEffect(function()
      if phase() ~= "tasks" then return end
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
      end
    end)

    hooks.useInput(function(input, key)
      if sweeping() and header_time_ms < SWEEP_MS then
        setSweeping(false)
        return
      end
      if phase() ~= "form" then
        if phase() == "done" or (phase() == "tasks" and scaffold_error()) then exit() end
        return
      end

      -- Ctrl+Enter (a real Kitty-protocol terminal can tell it apart from
      -- plain Enter) or its always-distinguishable fallback, Ctrl+S --
      -- see this file's header comment.
      if (key["return"] and key.ctrl) or (input == "s" and key.ctrl) then
        begin_submit()
        return
      end
      if key.tab then
        if key.shift then tab_move(-1) else tab_move(1) end
        return
      end
      if key["return"] then
        if STOPS[active()].field == "submit" then begin_submit() else tab_move(1) end
        return
      end
      if key.upArrow then move(-1); return end
      if key.downArrow then move(1); return end

      local field_name = STOPS[active()].field
      local is_text_field = field_name == "name" or field_name == "directory"

      if not is_text_field and input:match("^[1-4]$") then
        jump_to_group(tonumber(input))
        return
      end
      if not is_text_field and input == "?" then
        setCheat(not cheat())
        return
      end

      if field_name == "name" then
        if key.backspace or key.delete then setName(name():sub(1, -2))
        elseif input ~= "" and not key.ctrl and not key.escape then setName(name() .. input) end
        if not directory_touched then
          setDirectory(name() == "" and "." or ("./" .. name()))
        end
      elseif field_name == "directory" then
        directory_touched = true
        if key.backspace or key.delete then setDirectory(directory():sub(1, -2))
        elseif input ~= "" and not key.ctrl and not key.escape then setDirectory(directory() .. input) end
      elseif MULTI_OPTION_FIELDS[field_name] then
        -- ←/→ mirror ↑/↓ here (see this file's own header comment for why
        -- a vertically-stacked list is picked vertically): both step
        -- within the field first, then roll to the adjacent one.
        if key.leftArrow then move(-1) elseif key.rightArrow then move(1) end
      elseif field_name == "tailwind" then
        if input == " " or key.leftArrow or key.rightArrow then setTailwind(not tailwind()) end
      elseif field_name == "install_deps" then
        if input == " " or key.leftArrow or key.rightArrow then setInstallDeps(not install_deps()) end
      elseif field_name == "git_init" then
        if input == " " or key.leftArrow or key.rightArrow then setGitInit(not git_init()) end
      end
    end)

    -- The animated header is its own component so animation ticks re-render
    -- only these few rows, never the whole form. One ticker drives the
    -- sweep, the update spinner and the bubbles, and it is only READ (so
    -- only subscribed) while one of them is actually moving.
    local function Header()
      local anim = hooks.useAnimation({ interval = 100, isActive = true })
      return function()
        local columns = hooks.useWindowSize().columns or 80
        local status = update_status()
        local show_bubbles = phase() == "form" and columns >= 64
        local animating = show_bubbles or (status and status.state == "checking")
          or (sweeping() and header_time_ms < SWEEP_MS)
        local t = animating and anim.time() or header_time_ms
        header_time_ms = t
        local sweep_progress = (sweeping() and t < SWEEP_MS) and math.min(1, t / SWEEP_MS) or nil
        local title = logo.render({ columns = columns, version = VERSION, sweep = sweep_progress,
          frame = math.floor(t / 100), update_status = status })
        -- The diorama's last row is already the gap under the title; without
        -- it, a plain blank line keeps the same spacing.
        if show_bubbles then return bubbles.render_diorama({ time = t, columns = columns }, title) end
        return hydronium.h(ink.Box, { flexDirection = "column" }, title, hydronium.h(ink.Newline, {}))
      end
    end

    return function()
      local size = hooks.useWindowSize()
      local columns = size.columns or 80
      local header = hydronium.h(Header, { key = "header" })

      local current = active()
      local current_field = STOPS[current].field
      local active_group = STOPS[current].group
      local lines = {}
      local function push(prefix, element, dim)
        lines[#lines + 1] = hydronium.h(ink.Box, { key = #lines + 1, flexDirection = "row" },
          hydronium.h(ink.Text, { color = dim and "brightBlack" or "cyan", dimColor = dim }, prefix .. " "),
          element)
      end
      local function push_rows(rows, dim)
        for _, row in ipairs(rows) do push("\226\148\130", row, dim) end -- │
      end

      for group_number, title in ipairs(GROUP_TITLES) do
        local is_active_group = group_number == active_group
        local marker = is_active_group and "\226\151\134" or "\226\151\135" -- ◆ ◇
        push(marker, hydronium.h(ink.Text, { bold = is_active_group, dimColor = not is_active_group }, title), not is_active_group)
        push_rows({ hydronium.h(ink.Newline, {}) }, not is_active_group)

        if group_number == 1 then
          push_rows(field.text_field_rows({
            label = "name", value = name(), placeholder = "my-app", caret = current_field == "name",
            hint = "Used for the Moonstone package and project directory by default.",
            error = name_error(), group_dim = not is_active_group,
          }), not is_active_group)
          push_rows(field.text_field_rows({
            label = "directory", value = directory(), placeholder = ".", caret = current_field == "directory",
            hint = "Relative or absolute; follows the name above until you edit it.",
            group_dim = not is_active_group,
          }), not is_active_group)
        elseif group_number == 2 then
          push_rows(field.radio_group_rows({
            field_label = "framework", options = FRAMEWORKS, selected_id = framework_id(),
            active = current_field == "framework", group_dim = not is_active_group,
          }), not is_active_group)
          local router_opts = {}
          for i, r in ipairs(ROUTERS) do
            router_opts[i] = { id = r.id, label = r.label, description = r.description, recommended = r.recommended }
          end
          push_rows(field.radio_group_rows({
            field_label = "router", options = router_opts, selected_id = ROUTERS[router_index()].id,
            active = current_field == "router" and field_enabled("router"),
            field_disabled = not field_enabled("router"), field_disabled_reason = router_disabled_reason(),
            group_dim = not is_active_group,
          }), not is_active_group)
        elseif group_number == 3 then
          push_rows(field.toggle_rows({
            label = "Tailwind CSS v4", value = tailwind(), description = "@tailwindcss/vite + @source scanning for .luax/.lua files",
            active = current_field == "tailwind", disabled = not field_enabled("tailwind"),
            disabled_reason = tailwind_disabled_reason(), group_dim = not is_active_group,
          }), not is_active_group)
        else
          local pm_opts = {}
          for i, name_candidate in ipairs(PACKAGE_MANAGERS) do
            pm_opts[i] = { id = name_candidate, label = name_candidate, description = "Detected on PATH",
              disabled = not detected(name_candidate), disabled_reason = "not found on PATH" }
          end
          -- A field-level NOTE (distinct from a field-level DISABLED
          -- reason -- see ui/field.lua's own header comment on the two
          -- kinds): the field itself stays live for any Vite-based
          -- framework even when nothing was detected on PATH (files are
          -- still created either way), so this is informational, not a
          -- reason the field is unreachable.
          local pm_note = (#managers == 0 and field_enabled("package_manager"))
            and "none found on PATH -- files are still created; install one to run Vite" or nil
          push_rows(field.radio_group_rows({
            field_label = "package manager", options = pm_opts, selected_id = PACKAGE_MANAGERS[pm_index()],
            active = current_field == "package_manager" and field_enabled("package_manager"),
            field_disabled = not field_enabled("package_manager"), field_disabled_reason = "Only used by Vite-based frameworks",
            field_note = pm_note,
            group_dim = not is_active_group,
          }), not is_active_group)
          local interpreter_opts = {}
          for i, it in ipairs(INTERPRETERS) do
            local locked = INTERPRETER_LOCKED[framework_id()] and it.id ~= "luajit@2.1"
            interpreter_opts[i] = { id = it.id, label = it.label, description = it.description, recommended = it.recommended,
              disabled = locked, disabled_reason = locked and (FRAMEWORKS[framework_index()].label .. " requires LuaJIT") or nil }
          end
          push_rows(field.radio_group_rows({
            field_label = "interpreter", options = interpreter_opts, selected_id = INTERPRETERS[interpreter_index()].id,
            active = current_field == "interpreter", group_dim = not is_active_group,
          }), not is_active_group)
          push_rows(field.toggle_rows({
            label = "Install dependencies now", value = install_deps(),
            description = "Runs moon sync (and the JS install, if Tailwind is on) after scaffolding",
            active = current_field == "install_deps", group_dim = not is_active_group,
          }), not is_active_group)
          push_rows(field.toggle_rows({
            label = "git init", value = git_init(), description = "Initializes a git repository in the new project",
            active = current_field == "git_init", group_dim = not is_active_group,
          }), not is_active_group)
        end
      end

      -- Final rail node.
      local submit_active = current_field == "submit"
      local submit_label = "\226\150\144 Create " .. clip(name() == "" and "project" or name(), math.max(6, columns - 24)) .. " \226\150\140  \226\134\181"
      push("\226\151\134", hydronium.h(ink.Text, { bold = true, inverse = submit_active, color = "green" }, submit_label), false)

      local footer = hydronium.h(ink.Text, { key = "footer", color = "brightBlack" }, columns >= 64
        and "\226\134\145\226\134\147/\226\134\144\226\134\146 pick & move \194\183 space toggle \194\183 1-4 jump \194\183 ctrl+\226\134\181 create (ctrl+s fallback) \194\183 ? keys"
        or "\226\134\145\226\134\147 pick & move \194\183 ? keys")

      local cheat_panel = cheat() and hydronium.h(ink.Box, { key = "cheat", flexDirection = "column", borderStyle = "single", padding = 1 },
        hydronium.h(ink.Text, { bold = true }, "Keys"),
        hydronium.h(ink.Text, {}, "\226\134\145 / \226\134\147          move within a field, then roll to the next"),
        hydronium.h(ink.Text, {}, "\226\134\144 / \226\134\146 / space  same as \226\134\145/\226\134\147 for a radio; flips a toggle"),
        hydronium.h(ink.Text, {}, "Tab / Shift+Tab   jump straight to the next / previous field"),
        hydronium.h(ink.Text, {}, "1 2 3 4           jump to Project / Stack / Styling / Tooling"),
        hydronium.h(ink.Text, {}, "Enter             advance, or create from the final node"),
        hydronium.h(ink.Text, {}, "Ctrl+Enter        create from anywhere (Ctrl+S if your terminal can't tell)"),
        hydronium.h(ink.Text, {}, "?                 toggle this cheat sheet")
      ) or nil

      if phase() ~= "form" then
        local task_list = tasks()
        local body = {}
        if phase() == "tasks" and not scaffold_error() then
          -- Light chemistry pun in the STATUS line only, per the wizard's
          -- own voice guideline -- every label around it (field names,
          -- task labels) stays plain.
          body[#body + 1] = hydronium.h(ink.Text, { bold = true, color = "cyan" },
            "Protonating " .. (name() ~= "" and name() or "your project") .. "\226\128\166")
          body[#body + 1] = hydronium.h(ink.Newline, {})
        end
        body[#body + 1] = checklist_ui.render(task_list, task_anim.frame())
        if phase() == "done" then
          local res = scaffold_result()
          local any_task_error = false
          for _, t in ipairs(task_list) do if t.status == "error" then any_task_error = true end end
          body[#body + 1] = hydronium.h(ink.Newline, {})
          body[#body + 1] = hydronium.h(ink.Text, { bold = true, color = any_task_error and "yellow" or "green" },
            any_task_error and "Files are written, but a follow-up step failed -- see above."
            or (res.dry_run and "[DRY RUN] Solution ready." or "Solution ready."))
          body[#body + 1] = hydronium.h(ink.Text, {}, "Next steps:")
          if res.target_dir and res.target_dir ~= "." and res.target_dir ~= "./" then
            body[#body + 1] = hydronium.h(ink.Text, {}, "  cd " .. res.target_dir)
          end
          body[#body + 1] = hydronium.h(ink.Text, {}, "  moon run " .. tostring(res.next_script))
          body[#body + 1] = logo.render_rule({ columns = columns }) -- closing pH-gradient rule
        elseif scaffold_error() then
          body[#body + 1] = hydronium.h(ink.Newline, {})
          body[#body + 1] = hydronium.h(ink.Text, { color = "red" }, "Press any key to exit.")
        end
        return hydronium.h(ink.Box, { flexDirection = "column", paddingX = 1 },
          header, hydronium.h(ink.Box, { flexDirection = "column" }, lines),
          hydronium.h(ink.Newline, {}), hydronium.h(ink.Box, { flexDirection = "column" }, body))
      end

      return hydronium.h(ink.Box, { flexDirection = "column", paddingX = 1 },
        header,
        hydronium.h(ink.Box, { flexDirection = "column" }, lines),
        footer,
        cheat_panel)
    end
  end
end

return M
