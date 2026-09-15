--[[
  `hydronium` -- the Hydronium developer CLI.

    hydronium dev [--verbose] [--show-ips]

  `dev` spawns `meteorite dev` as a child process, tails the structured
  dev-event stream that child appends to `.meteorite/dev/events.log`,
  mirrors every event verbatim into this CLI's own durable
  `.hydronium/dev.log`, and renders a live status view with
  hydronium_ink.

  FLAG GRAMMAR, parsed explicitly below rather than by a library, because
  it is three tokens and every one of them must be exact: an unknown
  subcommand or an unknown flag is an error with a usage message, never a
  silent no-op. The only defaults are `verbose = false` and
  `show_ips = false`.

    --verbose    DISPLAY DENSITY ONLY. Shows more rows in the collapsed
                 events pane (event_model.VERBOSE_CAPACITY instead of
                 DEFAULT_CAPACITY). It deliberately does NOT enable
                 request header/body capture: that is heavier and
                 privacy-sensitive, belongs to the later fullscreen
                 request-debug mode, and will get its own differently
                 named flag when that ships. Nothing about what this CLI
                 captures or writes to .hydronium/dev.log changes with
                 this flag.
    --show-ips   Appends each request's `remote_addr` to its display
                 line. Opt-in, off by default, and independent of
                 --verbose. It does not change capture either: the
                 address is already in meteorite's event and is already
                 written to .hydronium/dev.log regardless -- this only
                 controls whether it is shown on screen.

  ENVIRONMENT ESCAPE HATCHES (development/verification only, deliberately
  not flags -- the flag grammar above is the whole public surface):

    HYDRONIUM_DEV_NO_SPAWN=1     do not start a child at all; only tail.
    HYDRONIUM_DEV_EVENTS=<path>  tail this file instead of
                                 .meteorite/dev/events.log.
    HYDRONIUM_DEV_LOG=<path>     write the durable log here instead of
                                 .hydronium/dev.log.
    HYDRONIUM_METEORITE_ARGS=<s> extra, whitespace-split arguments appended
                                 after `meteorite dev` when spawning it
                                 (e.g. "--mode hybrid_dev --backend
                                 fast_http") -- meteorite dev has no
                                 defaults of its own and errors without
                                 --mode/--backend at minimum.

  Together those let the whole UI be driven against a hand-seeded events
  file on a machine with no meteorite installed.
--]]

-- Resolve this package's own modules relative to THIS FILE, not the
-- current working directory -- `hydronium dev` is run from inside a
-- user's project, which is never this directory. Same technique
-- examples/ink_todo/run.lua uses and for the same reason.
local info = debug.getinfo(1, "S")
local this_dir = (info.source:gsub("^@", "")):match("^(.*)[/\\][^/\\]+$") or "."
local repo_root = this_dir .. "/../.."

package.path = this_dir .. "/?.lua;" .. this_dir .. "/?/init.lua;" .. package.path

-- Fallback only, exactly like examples/ink_todo/run.lua's: a no-op once
-- `moon sync` has materialized hydronium/hydronium_ink/hydronium_router
-- from this package's own moonstone.toml, and what makes a plain
-- `luajit cli/src/main.lua` from the hydronium checkout work too.
package.path = repo_root .. "/core/src/?.lua;" .. repo_root .. "/core/src/?/init.lua;"
  .. repo_root .. "/ink/src/?.lua;" .. repo_root .. "/ink/src/?/init.lua;"
  .. repo_root .. "/router/src/?.lua;" .. repo_root .. "/router/src/?/init.lua;"
  .. package.path

-- Every frame must reach the terminal immediately; see
-- examples/ink_demo/run.lua's identical call for the failure this avoids.
io.stdout:setvbuf("no")

local event_model = require("event_model")
local dev_supervisor = require("dev_supervisor")
local dev_log = require("dev_log")

local M = {}

M.VERSION = "0.1.0"

M.USAGE = table.concat({
  "hydronium " .. M.VERSION,
  "",
  "Usage:",
  "  hydronium dev [--verbose] [--show-ips]",
  "",
  "Commands:",
  "  dev            Run `meteorite dev` and render its dev-event stream.",
  "",
  "Options:",
  "  --verbose      Show more rows in the events pane (display density only).",
  "  --show-ips     Show each request's remote address.",
  "  -h, --help     Print this help.",
  "  -v, --version  Print the version.",
}, "\n")

--- @param argv string[]
--- @return table|nil parsed, string|nil err
function M.parse_args(argv)
  argv = argv or {}

  local first = argv[1]
  if first == nil then
    return nil, "no command given"
  end
  if first == "-h" or first == "--help" or first == "help" then
    return { command = "help" }
  end
  if first == "-v" or first == "--version" or first == "version" then
    return { command = "version" }
  end
  if first ~= "dev" then
    if first:sub(1, 1) == "-" then
      return nil, "unknown option '" .. first .. "' (expected a command first)"
    end
    return nil, "unknown command '" .. first .. "'"
  end

  local parsed = { command = "dev", verbose = false, show_ips = false }
  for index = 2, #argv do
    local token = argv[index]
    if token == "--verbose" then
      parsed.verbose = true
    elseif token == "--show-ips" then
      parsed.show_ips = true
    elseif token == "-h" or token == "--help" then
      return { command = "help" }
    else
      return nil, "unknown argument '" .. tostring(token) .. "' for `hydronium dev`"
    end
  end
  return parsed
end

--- How long to wait for a `startup` event before concluding the server is
--- probably up but has no dev-event emitter (an older meteorite). The UI
--- then says "server running", rather than spinning forever or erroring.
M.EVENTS_GRACE_MS = 6000

--- Cadence for the cheap-but-not-free shell probes (`kill -0`). One per
--- render tick would mean ~30 process spawns a second.
M.LIVENESS_INTERVAL_MS = 2000

--- One event-loop turn: drain the tailer, log everything, collapse for
--- display, then update the header state. Split out of `M.dev` so it is
--- readable and so the ordering (durable log FIRST, display second) is
--- explicit and cannot drift.
--- @return integer number of events applied
local function drain(ctx)
  local lines = ctx.supervisor:poll()
  if #lines == 0 then
    return 0
  end

  local applied = 0
  for _, line in ipairs(lines) do
    local event = event_model.parse_line(line)
    if event then
      -- Durable superset first, uncollapsed, every event, always.
      if ctx.log then
        ctx.log:append(event)
      end
      -- Display second, collapsed, capped at the visible row count.
      ctx.buffer:push(event)
      ctx.state:apply(event)
      applied = applied + 1
    else
      ctx.skipped = ctx.skipped + 1
    end
  end

  if applied > 0 then
    ctx.state.set_entries(ctx.buffer:snapshot())
  end
  return applied
end

--- @param parsed table From M.parse_args.
--- @return integer exit code
function M.dev(parsed)
  -- ui.app is required here, not at the top: it pulls in hydronium_ink,
  -- which pulls in the Yoga FFI binding. `hydronium --help` should not
  -- need a native library present.
  local ui = require("ui.app")
  local render = require("hydronium_ink.render")
  local hydronium = require("hydronium")

  local events_path = os.getenv("HYDRONIUM_DEV_EVENTS") or dev_supervisor.DEFAULT_EVENTS_PATH
  local log_path = os.getenv("HYDRONIUM_DEV_LOG") or dev_log.DEFAULT_PATH
  local should_spawn = os.getenv("HYDRONIUM_DEV_NO_SPAWN") ~= "1"

  -- `meteorite dev` itself requires --mode/--backend (it has no defaults
  -- of its own); a generated project's real invocation also carries
  -- --hybrid-profile, --router-dispatch, --lua-root, etc. Wiring
  -- hydronium-create's templates to assemble and pass these automatically
  -- is separate, deferred work (see the plan). Until then, this is the
  -- one way to actually reach the spawn path with a real project's flags.
  local argv = { "meteorite", "dev" }
  local extra_args = os.getenv("HYDRONIUM_METEORITE_ARGS")
  if extra_args then
    for word in extra_args:gmatch("%S+") do
      argv[#argv + 1] = word
    end
  end

  local supervisor = dev_supervisor.new_supervisor({
    argv = argv,
    events_path = events_path,
    spawn = should_spawn,
  })

  -- Start from the current end of any pre-existing file: a previous
  -- session's events are history, not this run's.
  supervisor.tailer:seek_to_end()

  local log, log_err = dev_log.open(log_path)
  if not log then
    io.stderr:write("hydronium dev: cannot open " .. log_path .. ": " .. tostring(log_err) .. "\n")
    return 1
  end

  local state = ui.new_state()
  local buffer = event_model.new_buffer({
    capacity = parsed.verbose and event_model.VERBOSE_CAPACITY or event_model.DEFAULT_CAPACITY,
    show_ips = parsed.show_ips,
  })

  local pid, spawn_err = supervisor:start()
  if should_spawn and not pid then
    log:append(dev_log.cli_event("build_error", { stage = "spawn", detail = tostring(spawn_err) }))
    log:close()
    io.stderr:write("hydronium dev: could not start `meteorite dev`: " .. tostring(spawn_err) .. "\n")
    return 1
  end

  log:append(dev_log.cli_event("startup", {
    command = "dev",
    verbose = parsed.verbose,
    show_ips = parsed.show_ips,
    events_path = events_path,
    child_pid = pid,
    spawned = should_spawn,
  }))

  local ctx = {
    supervisor = supervisor,
    buffer = buffer,
    state = state,
    log = log,
    skipped = 0,
  }

  -- Real wall-clock, not a count of loop turns. render.lua's loop paces
  -- itself at ~33ms per iteration when stdin is a real TTY, but its
  -- non-interactive fallback paces with `os.execute("sleep ...")`, whose
  -- per-turn cost is a whole process spawn -- counting turns and
  -- multiplying by 33 drifts badly there (measured: a nominal 6s of
  -- ticks took well over 9s of real time). The two timers below are
  -- coarse, so one clock read per turn is not worth optimizing away.
  local started_at = dev_log.now_ms()
  local last_probe_at = started_at
  local quitting = false

  local app = ui.create_app(state, {
    onQuit = function()
      quitting = true
    end,
  })

  local ok, err = pcall(render.render, hydronium.h(app), {
    onTick = function()
      drain(ctx)

      local now = dev_log.now_ms()
      if now - last_probe_at < M.LIVENESS_INTERVAL_MS then
        return
      end
      last_probe_at = now

      if should_spawn and pid and not supervisor:is_alive() then
        if state.status() ~= "down" then
          local event = dev_log.cli_event("server_exit", { pid = pid, reason = "child process gone" })
          log:append(event)
          buffer:push(event)
          state:apply(event)
          state.set_entries(buffer:snapshot())
        end
        return
      end

      -- Graceful degradation: an older meteorite with no dev-event
      -- emitter never creates the file. Say "server running" rather than
      -- spinning forever or treating a missing file as a failure.
      if state.status() == "starting"
        and supervisor:events_missing()
        and (now - started_at) >= M.EVENTS_GRACE_MS then
        state.set_status("ready")
        state.set_note("no dev-event stream at " .. events_path .. " (older meteorite?)")
      end
    end,
  })

  -- Final drain so events written between the last tick and the exit
  -- keypress still reach the durable log.
  pcall(drain, ctx)

  log:append(dev_log.cli_event("server_exit", {
    pid = pid,
    reason = quitting and "user quit" or (ok and "render loop ended" or "render error"),
  }))
  log:close()

  supervisor:stop()

  if not ok then
    io.stderr:write("hydronium dev: " .. tostring(err) .. "\n")
    return 1
  end
  return 0
end

--- @param argv string[]
--- @return integer exit code
function M.main(argv)
  local parsed, err = M.parse_args(argv)
  if not parsed then
    io.stderr:write("hydronium: " .. tostring(err) .. "\n\n" .. M.USAGE .. "\n")
    return 1
  end
  if parsed.command == "help" then
    io.stdout:write(M.USAGE .. "\n")
    return 0
  end
  if parsed.command == "version" then
    io.stdout:write("hydronium " .. M.VERSION .. "\n")
    return 0
  end
  return M.dev(parsed)
end

-- Executed directly (`luajit cli/src/main.lua dev`), as opposed to being
-- required by a spec.
if arg and arg[0] and arg[0]:match("main%.lua$") then
  os.exit(M.main(arg))
end

return M
