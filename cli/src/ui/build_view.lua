--[[
  hydronium-cli ui.build_view -- the `hydronium build` Ink view (M2).

  Modeled on ui/app.lua and ui/inspector_view.lua: an ordinary Hydronium
  component tree over hydronium_ink's Box/Text intrinsics, no bespoke
  renderer. Renders INLINE (render.lua's default -- `altScreen` is an
  opt-in session option this view does not set, per the milestone brief),
  so it appears in the caller's own scrollback like any other CLI output,
  not a full-screen takeover.

  Shows the planned steps up front from `plan().order` (so a long build
  never shows a blank screen while the first node runs) and fills each in
  as build_runner's own NDJSON events arrive, by driving a build_runner
  Runner (cli/src/build_runner.lua) directly from `onTick` -- the same
  cooperative coroutine every other output mode (--plain/--ndjson) drives
  through `build_runner.drain`.

  NO SPINNER. Deliberately out of scope for this view (see the milestone
  brief): a user who wants one is expected to build it themselves from
  `onTick`/`hydronium_ink.clock`, the same primitives this view itself
  uses for pacing.

  ARTIFACT LINKS. `<Text href="...">` (OSC 8 hyperlinks) already exists in
  hydronium_ink (ink/src/hydronium_ink/init.lua's "Public API for
  hyperlinks") and degrades to plain, unlinked text on its own for a
  terminal host/terminal.lua does not detect as supporting it -- this view
  always passes `href`, never checks capability itself, exactly like any
  other `<Text>` prop.
--]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local render = require("hydronium_ink.render")

local unpack = unpack or table.unpack

local M = {}

-- Only the 8 named ANSI colors this host speaks (hydronium_ink/color.lua's
-- own PALETTE) -- "gray" is not one of them (verified for real: it raised
-- "unknown palette color or invalid hex 'gray'" the first time this ran).
-- `pending`'s nil color relies on `dimColor` alone, same as ui/app.lua's
-- own dimColor-only rows.
local STATUS_ICON = {
  pending = { icon = "\194\183", color = nil }, -- ·
  started = { icon = "\226\150\184", color = "cyan" }, -- ▸
  finished = { icon = "\226\156\147", color = "green" }, -- ✓
  skipped = { icon = "\226\143\173", color = "yellow" }, -- ⏭
  failed = { icon = "\226\156\151", color = "red" }, -- ✗
}

--- How many pipeline steps to advance per onTick before yielding control
--- back to the render loop, at most -- keeps a build made of many fast
--- (sub-millisecond) nodes from being throttled to one node per ~33ms
--- frame, while still letting a slow node (a native task) simply take as
--- long as it takes inside a single `runner:step()` call, exactly as it
--- would headless. Not a time budget: `os.clock()`/`hydronium_ink.clock`
--- are wall/CPU clocks, not something worth reading in a hot loop here for
--- what is, in the fast case, sub-millisecond work per step anyway.
M.MAX_STEPS_PER_TICK = 25

--- @param plan table From Pipeline:plan() (`{ order, sinks, ... }`).
--- @return table state
local function new_state(plan)
  local steps, index_by_id = {}, {}
  for i, id in ipairs(plan.order) do
    steps[i] = { id = id, status = "pending" }
    index_by_id[id] = i
  end
  local get_revision, set_revision = hydronium.signal(0)
  local get_done, set_done = hydronium.signal(false)
  return {
    -- Plain table + revision signal (not a signal-of-a-table): the same
    -- pattern ui/app.lua's own `entries`/`requests_revision` uses, so
    -- mutating one row in place and bumping the revision is one cheap
    -- write instead of cloning the whole steps array every event.
    steps = steps,
    index_by_id = index_by_id,
    revision = get_revision, bump = function() set_revision(get_revision() + 1) end,
    done = get_done, set_done = set_done,
    final_status = nil, -- "done" | "error", set once done() is true
    final_result = nil,
    cancelled = false,
  }
end

--- Folds one build_runner event into the matching step row. Events for a
--- node id this state does not know about (should not happen: build_runner
--- only ever drains events written by the SAME run this state was built
--- from) are ignored rather than raising -- a display glitch must never be
--- what turns a successful build into a crashed CLI.
--- @param state table
--- @param events table[]
local function apply_events(state, events)
  local changed = false
  for _, event in ipairs(events) do
    if event.kind == "node" then
      local index = state.index_by_id[event.id]
      local step = index and state.steps[index]
      if step then
        if event.type == "task_started" then
          step.status = "started"
          step.plugin, step.method = event.plugin, event.method
        elseif event.type == "task_finished" then
          step.status = "finished"
          step.plugin, step.method = event.plugin, event.method
          step.duration_ms = event.duration_ms
          step.asset_count = event.asset_count
        elseif event.type == "task_skipped" then
          step.status = "skipped"
          step.plugin, step.method = event.plugin, event.method
          step.reason = event.reason
        elseif event.type == "task_failed" then
          step.status = "failed"
          step.plugin, step.method = event.plugin, event.method
          step.error = event.error
        end
        changed = true
      end
    end
  end
  if changed then
    state.bump()
  end
end

local function status_line(step)
  local meta = STATUS_ICON[step.status] or STATUS_ICON.pending
  local label = step.id
  if step.plugin and step.method then
    label = step.plugin .. "." .. step.method .. " (" .. step.id .. ")"
  end
  local detail = nil
  if step.status == "finished" then
    detail = string.format("%.1fms \194\183 %d asset(s)", step.duration_ms or 0, step.asset_count or 0)
  elseif step.status == "skipped" then
    detail = step.reason or "skipped"
  elseif step.status == "failed" then
    detail = step.error or "failed"
  end

  local children = {
    hydronium.h(ink.Text, { color = meta.color }, " " .. meta.icon .. " "),
    hydronium.h(ink.Text, { dimColor = step.status == "pending" }, label),
  }
  if detail then
    children[#children + 1] = hydronium.h(ink.Text, { dimColor = true, color = step.status == "failed" and "red" or nil },
      "  " .. detail)
  end
  return hydronium.h(ink.Box, { flexDirection = "row" }, unpack(children))
end

--- @param state table From new_state.
--- @return fun(): fun(): any A Hydronium component.
local function create_app(state)
  return function()
    -- Stashed on `state` (not a local captured only by this closure) so the
    -- OUTER `onTick` (render.render's own option, not a hook -- hooks can
    -- only be called from a component's setup) can call it once the runner
    -- finishes. See M.run.
    state.exit = hooks.useApp().exit

    hooks.useInput(function(input, key)
      key = key or {}
      if input == "q" or key.escape then
        state.cancelled = true
        state.exit()
      end
    end)

    return function()
      -- Read purely to subscribe: every mutation above bumps this, exactly
      -- like ui/app.lua's own requests_revision.
      state.revision()
      local rows = {}
      for _, step in ipairs(state.steps) do
        rows[#rows + 1] = status_line(step)
      end
      return hydronium.h(ink.Box, { flexDirection = "column" }, unpack(rows))
    end
  end
end

--- Runs the Ink view to completion and returns exactly what
--- `build_runner.drain` returns, so `main.lua`'s `M.build` treats every
--- output mode identically past this call (verify, the final summary line,
--- and the exit code are all shared, non-Ink code).
--- @param p Pipeline From build_runner.load.
--- @param build_runner table The build_runner module (injected so this has
---   no hydronium_ink -> build_runner -> hydronium_ink cycle risk and so a
---   spec can pass a fake).
--- @return "done"|"error" status
--- @return any result
--- @return table[]|nil sink_results
function M.run(p, build_runner)
  local runner = build_runner.new_runner(p)
  local state = new_state(runner.plan)

  local app = create_app(state)
  render.render(hydronium.h(app), {
    -- Drives the SAME cooperative Runner every other output mode drives
    -- through build_runner.drain -- see this module's own header comment.
    onTick = function()
      if state.done() or state.cancelled then
        return
      end
      for _ = 1, M.MAX_STEPS_PER_TICK do
        local status, result, events = runner:step()
        apply_events(state, events)
        if status ~= "yielded" then
          state.final_status, state.final_result = status, result
          state.set_done(true)
          state.exit()
          return
        end
      end
    end,
  })

  if state.cancelled and not state.done() then
    return "error", "build cancelled by user", nil
  end
  local sink_results = state.final_status == "done" and state.final_result or nil
  return state.final_status, state.final_result, sink_results
end

return M
