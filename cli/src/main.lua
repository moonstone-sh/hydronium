--[[
  `hydronium` -- the Hydronium developer CLI.

    hydronium dev [--verbose] [--show-ips] [--fullscreen]
                  [--meteorite-args "<flags>"]

  `dev` spawns `meteorite dev` as a child process, tails the structured
  dev-event stream that child appends to `.meteorite/dev/events.log`,
  mirrors every event verbatim into this CLI's own durable
  `.hydronium/dev.log`, and renders a live status view with
  hydronium_ink.

  FLAG GRAMMAR, parsed explicitly below rather than by a library, because
  it is a handful of tokens and every one of them must be exact: an
  unknown subcommand or an unknown flag is an error with a usage message,
  never a silent no-op. The only defaults are `verbose = false`,
  `show_ips = false` and `fullscreen = false`.

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
    --fullscreen Start in the FULLSCREEN REQUEST-DEBUG VIEW instead of
                 the compact status view (`f` toggles either way at
                 runtime, `esc` leaves it, `q` quits). The view takes
                 over the terminal's alternate screen buffer and lists
                 every request in .hydronium/dev.log -- the durable,
                 uncollapsed superset, not the 3-row display ring --
                 with a per-request detail pane. Like --verbose and
                 --show-ips this is DISPLAY ONLY: it captures nothing
                 extra, and the detail pane says so where meteorite's
                 event stream has nothing to show (no headers, no
                 bodies; see src/inspector.lua). A future
                 --capture-bodies (the flag --verbose's own comment
                 reserves) is a different thing entirely: it would
                 change what is CAPTURED, and this flag deliberately
                 does not.
    --meteorite-args "<flags>"
                 Whitespace-split arguments appended after `meteorite
                 dev` when spawning it, e.g.
                   --meteorite-args "--mode hybrid_dev --backend fast_http"
                 `meteorite dev` has NO defaults of its own and errors
                 without --mode/--backend at minimum, so a real project
                 always passes this; hydronium-create's generated
                 `[scripts] dev` does exactly that (see
                 create/src/create/templates/{ssr,islands}.lua).
                 WHY A FLAG AND NOT `--` PASSTHROUGH: `moon exec`
                 swallows the first `--` after the command it runs
                 ("One '--' after <command> is treated as an argument
                 delimiter and is not forwarded", `moon exec --help`),
                 so a generated script would need `-- --` to get one
                 through -- an invisible trap the first person to tidy
                 the line up would break. A named option needs no
                 delimiter at all. STATED LIMITATION: splitting on
                 whitespace means no individual argument can contain a
                 space. Nothing meteorite dev takes does today (modes,
                 backends and the lua-root path are all space-free).

  ENVIRONMENT ESCAPE HATCHES (development/verification only, deliberately
  not flags -- the flag grammar above is the whole public surface):

    HYDRONIUM_DEV_NO_SPAWN=1     do not start a child at all; only tail.
    HYDRONIUM_DEV_EVENTS=<path>  tail this file instead of
                                 .meteorite/dev/events.log.
    HYDRONIUM_DEV_LOG=<path>     write the durable log here instead of
                                 .hydronium/dev.log.
    HYDRONIUM_METEORITE_ARGS=<s> the same thing as --meteorite-args, from
                                 the environment, appended AFTER the flag's
                                 own words. Kept (it predates the flag) for
                                 exactly one job: adding or overriding a
                                 flag for one run without editing the
                                 project's committed dev script.

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
  "  hydronium dev [--verbose] [--show-ips] [--fullscreen]",
  "                [--meteorite-args \"<flags>\"]",
  "",
  "Commands:",
  "  dev            Run `meteorite dev` and render its dev-event stream.",
  "",
  "Options:",
  "  --verbose      Show more rows in the events pane (display density only).",
  "  --show-ips     Show each request's remote address.",
  "  --fullscreen   Start in the fullscreen request-debug view.",
  "  --meteorite-args \"<flags>\"",
  "                 Arguments for the spawned `meteorite dev`, e.g.",
  "                 \"--mode hybrid_dev --backend fast_http\". Required in",
  "                 practice: `meteorite dev` has no defaults of its own.",
  "  -h, --help     Print this help.",
  "  -v, --version  Print the version.",
  "",
  "Keys:",
  "  f              Toggle the fullscreen request-debug view.",
  "  j/k, up/down   Move the selected request (fullscreen only).",
  "  pgup/pgdn, g/G Page, or jump to the oldest/newest request.",
  "  esc            Leave the fullscreen view (or quit from the status view).",
  "  q, ctrl-c      Quit.",
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

  local parsed = {
    command = "dev",
    verbose = false,
    show_ips = false,
    fullscreen = false,
    meteorite_args = nil,
  }
  local index = 2
  while index <= #argv do
    local token = argv[index]
    if token == "--verbose" then
      parsed.verbose = true
    elseif token == "--show-ips" then
      parsed.show_ips = true
    elseif token == "--fullscreen" then
      parsed.fullscreen = true
    elseif token == "--meteorite-args" then
      -- Both spellings accepted. `--meteorite-args=...` is the form the
      -- generated dev script uses (one shell-quoted token, nothing for a
      -- script runner to mis-split); the separate-word form is what a
      -- human types interactively.
      local value = argv[index + 1]
      if value == nil then
        return nil, "--meteorite-args requires a value (e.g. --meteorite-args \"--mode hybrid_dev\")"
      end
      parsed.meteorite_args = value
      index = index + 1
    elseif token:sub(1, 17) == "--meteorite-args=" then
      parsed.meteorite_args = token:sub(18)
    elseif token == "-h" or token == "--help" then
      return { command = "help" }
    else
      return nil, "unknown argument '" .. tostring(token) .. "' for `hydronium dev`"
    end
    index = index + 1
  end
  return parsed
end

--- The exact argv the child is spawned with: `meteorite dev`, then the
--- --meteorite-args words, then HYDRONIUM_METEORITE_ARGS's words.
---
--- ORDER IS THE CONTRACT: the environment variable comes last so it can
--- override a flag the project's committed dev script already passes (for
--- every flag meteorite dev takes, the later occurrence is the one that
--- wins -- which is what makes a one-off `HYDRONIUM_METEORITE_ARGS="--mode
--- static_dev" moon run dev` work without editing moonstone.toml).
--- @param parsed table From M.parse_args.
--- @param env_args? string Contents of HYDRONIUM_METEORITE_ARGS.
--- @return string[]
function M.meteorite_argv(parsed, env_args)
  local argv = { "meteorite", "dev" }
  -- Appended one source at a time rather than via a `{flag, env}` array:
  -- with a nil flag that array's hole would make `ipairs` stop before ever
  -- reaching the environment's own words.
  local function append(source)
    if type(source) ~= "string" then
      return
    end
    for word in source:gmatch("%S+") do
      argv[#argv + 1] = word
    end
  end
  append(parsed and parsed.meteorite_args)
  append(env_args)
  return argv
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
      -- The fullscreen view's own history: uncollapsed, one row per
      -- request, fed from the same loop so the two views can never
      -- disagree about what happened. Ignores non-request events itself.
      ctx.state:record_request(event)
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
  -- --hybrid-profile, --router-dispatch, --lua-root, etc.
  -- hydronium-create's templates now assemble exactly those into the
  -- `--meteorite-args` of the `[scripts] dev` they generate (see
  -- create/src/create/templates/{ssr,islands}.lua), so a scaffolded
  -- project's `moon run dev` reaches this spawn path with its own real
  -- flags and nothing has to be set in the environment.
  local argv = M.meteorite_argv(parsed, os.getenv("HYDRONIUM_METEORITE_ARGS"))

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

  local state = ui.new_state({
    fullscreen = parsed.fullscreen,
    show_ips = parsed.show_ips,
  })
  local buffer = event_model.new_buffer({
    capacity = parsed.verbose and event_model.VERBOSE_CAPACITY or event_model.DEFAULT_CAPACITY,
    show_ips = parsed.show_ips,
  })

  -- Seed the fullscreen view's history from the durable log BEFORE this
  -- run appends anything to it, so the inspector really does show "every
  -- request event in .hydronium/dev.log" (that file is append-only across
  -- runs) rather than only the ones this session happened to see. Capped;
  -- see dev_log.read_events. Nothing is replayed into the status view or
  -- re-written to the log -- this is a read.
  local seeded = dev_log.read_events(log_path, {
    filter = event_model.is_request,
    limit = state.history.capacity,
  })
  state.history:push_all(seeded)
  if #seeded > 0 then
    state.set_selection(state.history:count())
  end

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
    fullscreen = parsed.fullscreen,
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
    -- --fullscreen starts in the alternate screen buffer, so the very
    -- first frame is already the fullscreen view rather than a status
    -- frame painted over the user's scrollback. `f` toggles it at runtime
    -- through hydronium_ink's useAltScreen (see ui/app.lua); render()
    -- guarantees leaving it on the way out, including on an error.
    altScreen = parsed.fullscreen,
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
