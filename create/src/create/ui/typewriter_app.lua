--[[
  hydronium-create "typewriter" wizard -- a PROTOTYPE alternate front-end
  for the exact same scaffold/task backend wizard_app.lua drives, built to
  judge a calmer, one-question-at-a-time interaction model. Opt-in only
  (`hydronium-create --wizard --typewriter`, see main.lua) -- it does not
  change wizard_app.lua's own default behavior, and reuses that file's
  step catalog/validation (create.ui.wizard_data), backend (create.init,
  create.wizard_tasks, create.update_check), and receipt presentation
  (create.ui.checklist) rather than duplicating any of it. The only truly
  NEW piece of UI is the linear commit flow itself, built on the new
  hydronium_ink.Static primitive (ink/src/hydronium_ink/init.lua).

  THE MODEL, top to bottom, exactly once each terminal has ever shown it:
    1. The brand line (create.ui.logo's one-line H3O+ wordmark, driven by
       ITS `sweep` prop -- unlike wizard_app.lua, which never actually
       calls logo.render and instead runs the separate multi-row
       fizzing/bubbles reaction diorama). It animates for one short sweep,
       then COMMITS -- becomes the very first `ink.Static` item -- and is
       never redrawn again. This is why the header must settle before
       anything else can commit: Static's own contract (see its doc
       comment) is that content, once written, is gone from the live
       frame forever, and this repo's inline host can only ever *append*
       to real scrollback -- a live region cannot sit both above AND below
       already-committed content. So the settle order is fixed: brand,
       then step 1, then step 2, ...
    2. One committed line per answered step ("✓ Project name  my-app"),
       each an `ink.Static` item -- frozen the instant Enter commits it,
       never rewritten afterward.
    3. Exactly one LIVE line below all of that: the step currently being
       asked (prompt, current value, a dim hint) -- the only thing this
       component ever repaints.
    4. `?` opens a small dim hint block under the live line (key bindings,
       plus `u` to (re)run create.update_check's real check -- there is no
       "apply the update" action anywhere in this codebase to reuse, so
       `u` only ever surfaces the SAME status wizard_app's header badge
       shows, on demand).
    5. Shift-Tab re-opens the MOST RECENTLY committed step as a new live
       line (pre-filled with its current value, never reset to a
       default); committing it again appends a NEW Static line marked
       "changed" -- the original committed line is untouched, exactly
       like a real typewriter: you cannot un-type a line, only add a
       correction below it. Repeated Shift-Tab walks further back.
    6. Once every applicable step is committed, the SAME task runner
       wizard_app.lua uses (create.wizard_tasks) drives the SAME
       checklist presentation (create.ui.checklist) to a compact receipt.
       This tail end is intentionally NOT built from `ink.Static`: a
       running task's spinner is inherently a redraw-in-place animation,
       the opposite of "write once" -- see this file's own "receipt"
       section below.

  STATED LIMITATION: the brand line's update-status badge freezes at
  whatever create.update_check last reported the MOMENT the intro
  animation settles (often before a real network check has resolved) --
  by design, nothing in Static ever gets rewritten. `?` then `u` is the
  documented way to see the current status live, in the hint block,
  without disturbing the frozen brand line.
--]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local signals = require("hydronium.signals")
local logo = require("create.ui.logo")
local fizzing = require("create.ui.fizzing")
local checklist_ui = require("create.ui.checklist")
local oklab = require("hydronium_oklab_utils")
local wizard_data = require("create.ui.wizard_data")

local M = {}

local VERSION = wizard_data.VERSION
local FRAMEWORKS, ROUTERS = wizard_data.FRAMEWORKS, wizard_data.ROUTERS
local PACKAGE_MANAGERS, INTERPRETERS = wizard_data.PACKAGE_MANAGERS, wizard_data.INTERPRETERS
local ROUTED, VITE_SUPPORTED = wizard_data.ROUTED, wizard_data.VITE_SUPPORTED
local TAILWIND_SUPPORTED, INTERPRETER_LOCKED = wizard_data.TAILWIND_SUPPORTED, wizard_data.INTERPRETER_LOCKED
local index_of_id, shallow_copy = wizard_data.index_of_id, wizard_data.shallow_copy
local name_problem, clip = wizard_data.name_problem, wizard_data.clip

-- Same accent this repo's stepped wizard uses (wizard_app.lua's own
-- ACCENT), reproduced rather than imported: wizard_app.lua does not
-- export it, and it is three lines of pure presentation, not logic this
-- file would otherwise risk drifting out of sync on.
local ACCENT_OKLCH = oklab.oklch(0.72, 0.13, 250)
local ACCENT = ink.byProfile({ truecolor = ACCENT_OKLCH, ansi256 = ACCENT_OKLCH, ansi16 = "brightBlue" })
local DIM = { dimColor = true }

-- The linear step sequence, in the order they are ever asked. `applicable`
-- decides whether a step is asked at all for the CURRENT framework choice
-- (mirrors wizard_app.lua's own `stop_enabled`, flattened -- there are no
-- pages/groups here, just one line at a time). "interpreter" is special:
-- when the chosen framework is LuaJIT-locked (ink/love), it is never
-- asked at all -- see `auto_interpreter_note` below, which commits it
-- automatically the moment "framework" itself commits, the same
-- auto-correction wizard_app.lua's own `select_stop` performs.
local STEP_IDS = {
  "name", "directory", "framework", "router", "tailwind",
  "package_manager", "interpreter", "install_deps", "git_init",
}
local function applicable(id, framework_id)
  if id == "router" then return ROUTED[framework_id] == true end
  if id == "tailwind" then return TAILWIND_SUPPORTED[framework_id] == true end
  if id == "package_manager" then return VITE_SUPPORTED[framework_id] == true end
  if id == "interpreter" then return not INTERPRETER_LOCKED[framework_id] end
  return true
end

local STEP_LABEL = {
  name = "Project name", directory = "Directory", framework = "Framework",
  router = "Router", tailwind = "Tailwind CSS", package_manager = "Package manager",
  interpreter = "Interpreter", install_deps = "Install dependencies", git_init = "Initialize Git",
}

function M.create_typewriter_app(opts)
  opts = opts or {}
  local create_mod = opts.create_mod or require("create.init")
  local pm_mod = opts.pm_mod or require("create.pm")
  local wizard_tasks = opts.wizard_tasks_mod or require("create.wizard_tasks")
  local update_check_mod = opts.update_check_mod or require("create.update_check")
  local dry_run = opts.dry_run
  if dry_run == nil then dry_run = true end -- Lab is always side-effect free.
  -- `opts.intro == false` (CI, NO_COLOR -- see main.lua's own call site)
  -- settles the header immediately, exactly like reduced motion does --
  -- the only thing either one affects in this file is the header's own
  -- one-time sweep, so one flag covers both (unlike wizard_app.lua, which
  -- keeps them conceptually separate because its OWN reduced_motion also
  -- freezes the multi-row fizzing/bubbles diorama this file never has).
  local reduced_motion = opts.reduced_motion == true or opts.intro == false
    or os.getenv("HYDRONIUM_REDUCED_MOTION") == "1"

  -- One reaction per run, reused ONLY for its timing figures (`timeline`/
  -- `final_time`) -- never rendered -- to time how long the brand line's
  -- own `logo.render` sweep animates before it settles and commits. See
  -- this file's own header comment for why wizard_app.lua's separate
  -- multi-row fizzing/bubbles diorama has no place in a one-line header.
  local reaction = opts.reaction or fizzing.pick(opts.seed)
  local reaction_timeline = fizzing.timeline(reaction, opts.ascii)

  return function()
    local exit = hooks.useApp().exit
    local managers = pm_mod.detect()
    local function detected(name)
      for _, m in ipairs(managers) do if m == name then return true end end
      return false
    end

    -- Same field signals wizard_app.lua owns, same defaults -- see that
    -- file for why each default is what it is (package manager auto-
    -- detected, install/git on by default, etc).
    local name, setName = signals.createSignal(opts.name or "")
    local directory_touched = opts.directory ~= nil
    local directory, setDirectory = signals.createSignal(opts.directory or ((opts.name and opts.name ~= "") and ("./" .. opts.name) or "."))
    local name_error, setNameError = signals.createSignal(nil)
    local framework_index, setFrameworkIndex = signals.createSignal(index_of_id(FRAMEWORKS, opts.initial_framework_id, 1))
    local router_index, setRouterIndex = signals.createSignal(index_of_id(ROUTERS, opts.initial_router_id, 1))
    local tailwind, setTailwind = signals.createSignal(opts.initial_tailwind == true)
    local default_pm_index = 1
    for i, name_candidate in ipairs(PACKAGE_MANAGERS) do if detected(name_candidate) then default_pm_index = i break end end
    local pm_index, setPmIndex = signals.createSignal(index_of_id(PACKAGE_MANAGERS, opts.initial_package_manager_id, default_pm_index))
    local interpreter_index, setInterpreterIndex = signals.createSignal(
      INTERPRETER_LOCKED[FRAMEWORKS[framework_index()].id] and 1 or index_of_id(INTERPRETERS, opts.initial_interpreter_id, 1))
    local install_deps, setInstallDeps = signals.createSignal(opts.initial_install_deps ~= false)
    local git_init, setGitInit = signals.createSignal(opts.initial_git_init ~= false)
    local function framework_id() return FRAMEWORKS[framework_index()].id end

    local function field_value(id)
      if id == "name" then return name() end
      if id == "directory" then return directory() end
      if id == "framework" then return FRAMEWORKS[framework_index()].label end
      if id == "router" then return ROUTERS[router_index()].label end
      if id == "tailwind" then return tailwind() and "On" or "Off" end
      if id == "package_manager" then return PACKAGE_MANAGERS[pm_index()] end
      if id == "interpreter" then return INTERPRETERS[interpreter_index()].label end
      if id == "install_deps" then return install_deps() and "Yes" or "No" end
      if id == "git_init" then return git_init() and "Yes" or "No" end
    end

    -- The step sequence for the CURRENT framework choice -- recomputed on
    -- every read (framework can only ever be answered once ahead of every
    -- conditional step, so this never destabilizes mid-flow).
    local function sequence()
      local list = {}
      for _, id in ipairs(STEP_IDS) do if applicable(id, framework_id()) then list[#list + 1] = id end end
      return list
    end

    -- `committed`: append-only, exactly what flows into `ink.Static`
    -- (see this file's header comment). Each record is `{ id, note }` --
    -- `note` is nil (a normal first answer), "changed" (a Shift-Tab
    -- correction), or "auto" (framework forced it, e.g. LuaJIT on ink/
    -- love -- never asked as its own step at all). Values are read live
    -- from the field signals above at RENDER time, not snapshotted into
    -- the record -- correct because a committed record's field can never
    -- change again except through an explicit correction, which appends
    -- its OWN new record rather than mutating this one.
    -- Update-status plumbing (identical contract to wizard_app.lua's own):
    -- `opts.update_status` lets a Lab story force a specific state; the
    -- real check only ever runs when `opts.check_updates` opts in. These
    -- are plain Lua locals (never reactive signals), so reading or
    -- advancing them is always safe, including from setup below -- unlike
    -- a signal write, which the initial `committed`/`header_committed`
    -- values just below need to stay clear of entirely (see this file's
    -- own note on ERR_RENDER_MUTATION further down).
    local update_handle
    local settled_status = opts.update_status
    local function update_status()
      if update_handle then
        local ok, status = pcall(update_handle.poll)
        status = ok and status or nil
        if not (status and status.state == "checking") then settled_status, update_handle = status, nil end
        return status
      end
      return settled_status
    end
    if opts.update_status == nil and opts.check_updates then
      local ok, handle = pcall(update_check_mod.start, VERSION)
      update_handle = ok and handle or nil
    end

    -- `committed`: append-only, exactly what flows into `ink.Static` (see
    -- this file's header comment). Reduced motion starts the header
    -- ALREADY committed -- baked into this signal's INITIAL value, never
    -- fixed up by a later write from an effect (see the "ERR_RENDER_
    -- MUTATION" note further down for exactly why that would be unsafe).
    local committed, setCommitted = signals.createSignal(
      reduced_motion and { { id = "__header", note = nil, n = 1, header_status = update_status() } } or {})
    local function commit_record(id, note)
      local copy = shallow_copy(committed())
      copy[#copy + 1] = { id = id, note = note, n = #copy + 1 }
      setCommitted(copy)
    end

    local step_index, setStepIndex = signals.createSignal(1)
    -- The step currently being CORRECTED (Shift-Tab), or nil for the
    -- ordinary forward flow. An integer INDEX into `committed()` -- not a
    -- field id -- so repeated Shift-Tab walks further back one committed
    -- record at a time, and committing a correction always resumes
    -- forward progress exactly where `step_index` already was (a
    -- correction never rewinds the main flow, see this file's header
    -- comment point 5).
    local correcting, setCorrecting = signals.createSignal(nil)
    local hints_open, setHintsOpen = signals.createSignal(false)
    -- `update_status()` (below) reads plain Lua locals, not a signal, so
    -- pressing `u` (which only ever mutates those locals) would otherwise
    -- leave the hint block showing a stale status until some UNRELATED
    -- keystroke happened to force a re-render. Bumped once per `u` press
    -- purely so this component subscribes to SOMETHING and re-evaluates
    -- `update_status()` right away.
    local hint_tick, setHintTick = signals.createSignal(0)

    -- A per-step "value in progress" for a CHOICE step's highlighted
    -- option, reset to the field's own current index every time a choice
    -- step becomes live (entering it fresh, or via a correction) --
    -- arrow/j/k only ever move this; Enter is what actually commits it
    -- into the real field signal.
    local highlight, setHighlight = signals.createSignal(nil)
    local function choice_options(id)
      if id == "framework" then return FRAMEWORKS end
      if id == "router" then return ROUTERS end
      if id == "package_manager" then return PACKAGE_MANAGERS end
      if id == "interpreter" then return INTERPRETERS end
      return nil
    end
    local function choice_index(id)
      if id == "framework" then return framework_index() end
      if id == "router" then return router_index() end
      if id == "package_manager" then return pm_index() end
      if id == "interpreter" then return interpreter_index() end
    end
    local function set_choice_index(id, index)
      if id == "framework" then setFrameworkIndex(index)
      elseif id == "router" then setRouterIndex(index)
      elseif id == "package_manager" then setPmIndex(index)
      elseif id == "interpreter" then setInterpreterIndex(index) end
    end

    -- The step id CURRENTLY live: either the one being corrected, or the
    -- next one forward progress hasn't reached yet.
    local function live_id()
      local c = correcting()
      if c then return committed()[c] and committed()[c].id or nil end
      local seq = sequence()
      return seq[step_index()]
    end
    -- Resets `highlight` to match whichever choice step just became live,
    -- pre-filled at its CURRENT stored value (never option 1) -- called
    -- explicitly at every transition point (see commit_current's forward
    -- advance and begin_correction below) rather than from a
    -- hydronium.createEffect: an effect triggered by the SAME signal
    -- write that also re-renders this component is not guaranteed to run
    -- BEFORE that render reads `highlight()` (effects and renders are
    -- separate scheduler queues -- see core/scheduler.lua), which
    -- produced a real, reproducible crash here (a stale `highlight` from
    -- the PREVIOUS choice step, out of range for the new one's option
    -- list). Calling this synchronously, in the same event-handler pass
    -- that changes what is live, has no such race.
    local function sync_highlight(id)
      setHighlight(id and choice_options(id) and (choice_index(id) or 1) or nil)
    end

    local function validate_name()
      local trimmed = name():match("^%s*(.-)%s*$")
      local problem = name_problem(trimmed)
      if problem then setNameError(problem); return false end
      setName(trimmed); setNameError(nil); return true
    end

    -- Auto-corrects (and auto-COMMITS, since it is never its own asked
    -- step) the interpreter the instant "framework" commits onto a
    -- LuaJIT-locked template -- exactly wizard_app.lua's own
    -- `select_stop` framework branch, adapted to append a visible history
    -- line instead of a transient notice banner (there is no room for a
    -- separate notice line in a one-line-at-a-time flow -- the committed
    -- line itself IS the notice).
    local function maybe_auto_interpreter()
      if INTERPRETER_LOCKED[framework_id()] then
        setInterpreterIndex(index_of_id(INTERPRETERS, "luajit@2.1", interpreter_index()))
        commit_record("interpreter", "auto")
      end
    end

    local phase, setPhase = signals.createSignal("form") -- "form" | "tasks" | "done"
    local tasks, setTasks = signals.createSignal({})
    local scaffold_result, setScaffoldResult = signals.createSignal(nil)
    local scaffold_error, setScaffoldError = signals.createSignal(nil)
    local task_anim = hooks.useAnimation({ interval = 120, isActive = true })

    local function begin_submit()
      local id = framework_id()
      local values = {
        directory = directory(), name = name(), template = id,
        force = opts.force, dry_run = dry_run, interpreter = INTERPRETERS[interpreter_index()].id,
      }
      if VITE_SUPPORTED[id] then values.tailwind = tailwind(); values.package_manager = PACKAGE_MANAGERS[pm_index()] end
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
      local plan = wizard_tasks.plan({ install_deps = install_deps(), vite = res.vite, git_init = git_init(), package_manager = res.package_manager })
      plan[1] = { id = plan[1].id, label = plan[1].label, status = "done" }
      for i = 2, #plan do plan[i] = { id = plan[i].id, label = plan[i].label, status = "pending" } end
      setTasks(plan)
      setPhase("tasks")
      if #plan == 1 then
        setPhase("done")
        if opts.onDone then opts.onDone(res, nil) end
        if opts.auto_exit then exit() end
      end
    end

    -- Identical pacing/shape to wizard_app.lua's own task-advancing
    -- effect -- see that file's header comment for the stated one-
    -- step-per-run pacing choice. Reused verbatim rather than imported: it
    -- is a `hydronium.createEffect` closure over this component's OWN
    -- signals, which cannot be factored out without turning it into a
    -- second, parallel component contract.
    hydronium.createEffect(function()
      if phase() ~= "tasks" then return end
      task_anim.frame()
      local list = tasks()
      for i, t in ipairs(list) do
        if t.status == "running" then
          local res = scaffold_result()
          local ok, err = wizard_tasks.run_task(t, {
            target_dir = res and res.target_dir or directory(), package_manager = res and res.package_manager,
            dry_run = dry_run, run_process = opts.run_process,
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
      if scaffold_result() then
        setPhase("done")
        if opts.onDone then opts.onDone(scaffold_result(), scaffold_error()) end
        if opts.auto_exit then exit() end
      end
    end)

    -- Commits whatever the live step currently holds and advances --
    -- forward progress if this was the ordinary next step, or a "changed"
    -- correction line if `correcting` was set (which always resumes
    -- forward progress exactly where it was, never rewinding it).
    local function commit_current()
      local id = live_id()
      if not id then return end
      if id == "name" and not validate_name() then return end
      local was_correcting = correcting() ~= nil
      commit_record(id, was_correcting and "changed" or nil)
      if was_correcting then
        setCorrecting(nil)
        sync_highlight(live_id())
      else
        if id == "framework" then maybe_auto_interpreter() end
        local next_index = step_index() + 1
        setStepIndex(next_index)
        if next_index > #sequence() then begin_submit() else sync_highlight(sequence()[next_index]) end
      end
    end

    local function begin_correction()
      local history = committed()
      local from = correcting() or (#history + 1)
      if from <= 1 then return end
      setCorrecting(from - 1)
      sync_highlight(history[from - 1] and history[from - 1].id or nil)
    end

    -- === Header: one line, plays once, then settles into Static ===
    -- `header_committed`'s initial value (true under reduced motion) is
    -- what actually makes reduced motion start "already settled" -- see
    -- `committed`'s own initial value above, seeded with the header
    -- record for exactly the same reason: a signal WRITE (e.g.
    -- `setHeaderCommitted(true)` called unconditionally here during
    -- setup) would hit core/component.lua's ERR_RENDER_MUTATION guard,
    -- since setup runs as part of the initial render pass, which must
    -- stay pure. Choosing the right INITIAL value has no such
    -- restriction -- it is not a mutation, just what the signal starts as.
    local intro_duration = reaction_timeline.faded_at
    local header_committed, setHeaderCommitted = signals.createSignal(reduced_motion)
    local function commit_header(snapshot_status)
      if header_committed() then return end
      setHeaderCommitted(true)
      local copy = shallow_copy(committed())
      table.insert(copy, 1, { id = "__header", note = nil, n = 0, header_status = snapshot_status })
      -- Renumber so keys stay stable and unique after an in-place insert.
      for i, rec in ipairs(copy) do rec.n = i end
      setCommitted(copy)
    end

    -- `isActive` is read once at setup, not reactively (see useAnimation's
    -- own doc comment); reduced motion never needs this ticker at all
    -- (the header is already committed -- see above), so it stays
    -- inactive there rather than animating pointlessly off-screen.
    local anim = hooks.useAnimation({ interval = 30, isActive = not reduced_motion })
    if not reduced_motion then
      hydronium.createEffect(function()
        if header_committed() then return end
        if anim.time() >= intro_duration then commit_header(update_status()) end
      end)
    end

    local function header_line(columns)
      if reduced_motion then return logo.render({ columns = columns, version = VERSION, update_status = update_status() }) end
      local t = anim.time()
      local sweep = t >= intro_duration and nil or (intro_duration > 0 and math.min(t / intro_duration, 1) or nil)
      return logo.render({ columns = columns, version = VERSION, sweep = sweep, update_status = update_status() })
    end

    -- === Committed-line rendering (the ink.Static payload) ===
    local function committed_line(rec)
      if rec.id == "__header" then
        -- Frozen forever at whatever `logo.render` looked like the instant
        -- it settled -- see this file's STATED LIMITATION comment.
        return hydronium.h(ink.Box, { key = "c" .. rec.n, flexDirection = "row" },
          hydronium.h(ink.Text, { color = ACCENT, bold = true }, "H\226\130\131O\226\129\186 "),
          hydronium.h(ink.Text, { color = "brightBlack" }, "hydronium/create v" .. VERSION))
      end
      local mark, mark_color = "\226\156\147 ", "green" -- ✓
      local suffix = ""
      if rec.note == "changed" then mark, mark_color, suffix = "\226\134\186 ", "yellow", "  (changed)" -- ↺
      elseif rec.note == "auto" then mark, mark_color, suffix = "\194\183 ", "brightBlack", "  (auto)" end
      return hydronium.h(ink.Box, { key = "c" .. rec.n, flexDirection = "row" },
        hydronium.h(ink.Text, { color = mark_color }, mark),
        -- 22, not 20: the longest label ("Install dependencies") is
        -- exactly 20 cells, so a %-20s field would butt its value
        -- directly against it with no gap at all.
        hydronium.h(ink.Text, {}, string.format("%-22s", STEP_LABEL[rec.id] or rec.id)),
        hydronium.h(ink.Text, { bold = true }, field_value(rec.id) or ""),
        suffix ~= "" and hydronium.h(ink.Text, DIM, suffix) or nil)
    end

    -- === The one live line, plus its optional hint block ===
    local function live_line(columns, id)
      local label = STEP_LABEL[id] or id
      local options = choice_options(id)
      local is_text = id == "name" or id == "directory"
      local hint
      local body
      if is_text then
        local value = id == "name" and name() or directory()
        local placeholder = (id == "name" and value == "" and "my-app") or nil
        body = hydronium.h(ink.Box, { flexDirection = "row" },
          hydronium.h(ink.Text, { bold = true, color = ACCENT }, label .. "  "),
          hydronium.h(ink.Text, { bold = true }, value .. "\226\150\141"), -- ▍
          placeholder and hydronium.h(ink.Text, DIM, "  " .. placeholder) or nil)
        local problem = name_error() or (id == "name" and value ~= "" and name_problem(value))
        hint = problem and ("  " .. problem) or "  Enter confirm"
      elseif options then
        -- Defensive clamp, belt-and-suspenders alongside sync_highlight's
        -- own explicit resets at every transition point: `highlight` must
        -- never be read out of THIS step's own option range, whatever the
        -- reason (a real, reproduced bug here was a stale value left over
        -- from the PREVIOUS choice step's longer option list).
        local idx = highlight() or choice_index(id) or 1
        if idx < 1 or idx > #options then idx = choice_index(id) or 1 end
        local option = options[idx]
        local option_label = type(option) == "table" and option.label or option
        body = hydronium.h(ink.Box, { flexDirection = "row" },
          hydronium.h(ink.Text, { bold = true, color = ACCENT }, label .. "  "),
          hydronium.h(ink.Text, { bold = true }, "\226\151\143 " .. option_label), -- ●
          hydronium.h(ink.Text, DIM, string.format("  (%d/%d)", idx, #options)))
        hint = "  \226\134\145\226\134\147 choose \194\183 Enter confirm"
      else
        local on = (id == "tailwind" and tailwind()) or (id == "install_deps" and install_deps()) or (id == "git_init" and git_init())
        body = hydronium.h(ink.Box, { flexDirection = "row" },
          hydronium.h(ink.Text, { bold = true, color = ACCENT }, label .. "  "),
          hydronium.h(ink.Text, { bold = true }, (on and "\226\150\160 On" or "\226\150\161 Off")))
        hint = "  Space toggle \194\183 Enter confirm"
      end
      local rows = { body, hydronium.h(ink.Text, DIM, clip(hint, columns)) }
      if correcting() then table.insert(rows, 1, hydronium.h(ink.Text, { color = "yellow" }, "Editing a previous answer \226\128\148 Enter to save as a new line")) end
      if hints_open() then
        rows[#rows + 1] = hydronium.h(ink.Text, DIM, "?  hide hints")
        rows[#rows + 1] = hydronium.h(ink.Text, DIM, "Shift-Tab  edit the previous answer \194\183 Ctrl-C  cancel")
        hint_tick() -- subscribe: re-read update_status() the instant `u` bumps this, see its own doc comment
        local status = update_status()
        local status_text = status and status.state == "checking" and "checking for updates\226\128\166"
          or status and status.state == "available" and ("update available: v" .. tostring(status.latest))
          or status and "up to date" or "press u to check for updates"
        rows[#rows + 1] = hydronium.h(ink.Text, DIM, "u  " .. status_text)
      else
        rows[#rows + 1] = hydronium.h(ink.Text, DIM, "?  hints")
      end
      return hydronium.h(ink.Box, { key = "live", flexDirection = "column" }, rows)
    end

    hooks.useInput(function(input, key)
      if phase() ~= "form" then
        if phase() == "done" or scaffold_error() then exit() end
        return
      end
      if key.tab and key.shift then begin_correction(); return end
      local id = live_id()
      if not id then return end
      local is_text = id == "name" or id == "directory"
      if not is_text and input == "?" then setHintsOpen(not hints_open()); return end
      if hints_open() and input == "u" and not is_text then
        local ok, handle = pcall(update_check_mod.start, VERSION)
        update_handle = ok and handle or update_handle
        setHintTick(hint_tick() + 1)
        return
      end
      local options = choice_options(id)
      if options and not is_text then
        if key.upArrow or input == "k" then setHighlight(((highlight() or 1) - 2) % #options + 1); return end
        if key.downArrow or input == "j" then setHighlight((highlight() or 1) % #options + 1); return end
        if key["return"] then set_choice_index(id, highlight() or choice_index(id)); commit_current(); return end
        return
      end
      if key["return"] then commit_current(); return end
      if is_text then
        if key.backspace or key.delete then
          if id == "name" then setName(name():sub(1, -2)) else setDirectory(directory():sub(1, -2)) end
        elseif input ~= "" and not key.ctrl then
          if id == "name" then setName(name() .. input) else directory_touched = true; setDirectory(directory() .. input) end
        end
        if id == "name" then
          if name_error() and not name_problem(name()) then setNameError(nil) end
          if not directory_touched then setDirectory(name() == "" and "." or ("./" .. name())) end
        end
        return
      end
      -- Remaining kinds are the three toggles.
      if input == " " then
        if id == "tailwind" then setTailwind(not tailwind())
        elseif id == "install_deps" then setInstallDeps(not install_deps())
        elseif id == "git_init" then setGitInit(not git_init()) end
      end
    end)

    return function()
      local size = hooks.useWindowSize()
      local columns = size.columns or 80

      local static_items = {}
      for _, rec in ipairs(committed()) do static_items[#static_items + 1] = committed_line(rec) end

      if phase() == "form" then
        local id = live_id()
        return hydronium.h(ink.Box, { flexDirection = "column", paddingX = 1, inlineViewport = true },
          hydronium.h(ink.Static, { key = "history" }, static_items),
          not header_committed() and hydronium.h(ink.Box, { key = "header" }, header_line(columns)) or nil,
          id and live_line(columns, id) or nil)
      end

      -- Receipt: intentionally NOT Static (see this file's header
      -- comment) -- a running task's spinner must keep repainting in
      -- place, and the whole point of Static is that its content never
      -- does. `checklist_ui.render` is the exact component wizard_app.lua
      -- uses for the same phase.
      local done = phase() == "done"
      local failed = false
      for _, t in ipairs(tasks()) do if t.status == "error" then failed = true end end
      local lines = {}
      if done then
        local res = scaffold_result()
        lines[#lines + 1] = hydronium.h(ink.Text, { key = "title", bold = true, color = failed and "yellow" or "green" },
          (failed and "Created " or "\226\156\148 Created ") .. name() .. (res and res.dry_run and "  (dry run)" or ""))
      else
        lines[#lines + 1] = hydronium.h(ink.Text, { key = "title", bold = true, color = ACCENT }, "Creating " .. name())
      end
      lines[#lines + 1] = hydronium.h(ink.Box, { key = "checklist" }, checklist_ui.render(tasks(), phase() == "tasks" and task_anim.frame() or 0))
      if scaffold_error() then lines[#lines + 1] = hydronium.h(ink.Text, { key = "err", color = "red" }, tostring(scaffold_error())) end
      if done then
        local res = scaffold_result()
        if failed then lines[#lines + 1] = hydronium.h(ink.Text, { key = "failnote", color = "yellow" }, "Files were created; the steps marked \226\156\150 need attention.") end
        lines[#lines + 1] = hydronium.h(ink.Text, { key = "next", bold = true }, "Next steps")
        if res.target_dir and res.target_dir ~= "." then
          lines[#lines + 1] = hydronium.h(ink.Text, { key = "cd", color = ACCENT }, "  cd " .. string.format("%q", res.target_dir))
        end
        if not install_deps() then
          lines[#lines + 1] = hydronium.h(ink.Text, { key = "sync", color = ACCENT }, "  moon sync")
          if res.vite then
            lines[#lines + 1] = hydronium.h(ink.Text, { key = "jsinstall", color = ACCENT },
              "  " .. (res.package_manager or PACKAGE_MANAGERS[pm_index()]) .. " install")
          end
        end
        lines[#lines + 1] = hydronium.h(ink.Text, { key = "run", color = ACCENT }, "  moon run " .. tostring(res.next_script))
      end
      return hydronium.h(ink.Box, { flexDirection = "column", paddingX = 1, inlineViewport = true },
        hydronium.h(ink.Static, { key = "history" }, static_items),
        hydronium.h(ink.Box, { key = "receipt", flexDirection = "column" }, lines))
    end
  end
end

return M
