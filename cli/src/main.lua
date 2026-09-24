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
                 forwards everything after its own `--` verbatim,
                 including any further `--` the child wants for itself
                 (verified: `moon exec -- printf '[%s]' -- -- x`
                 prints `[--][--][x]`) -- `--` passthrough to
                 `hydronium dev` would work mechanically. The real
                 reason not to use it: `moon run` hands the script
                 body to the host shell before Moonstone ever parses
                 it, so a generated `[scripts] dev` line would depend
                 on the shell quoting multiple space-separated flags
                 correctly and keeping them together across edits. A
                 named option folds the whole flag set into ONE shell-
                 quoted string instead, so it either survives re-
                 quoting as one token or breaks visibly.
                 STATED LIMITATION: splitting on
                 whitespace means no individual argument can contain a
                 space. Nothing meteorite dev takes does today (modes,
                 backends and the lua-root path are all space-free).
    --vite       Start `vite dev` ALONGSIDE `meteorite dev`, the two
                 merged into one dev loop (docs/HYDRONIUM_WEB_VITE_ADAPTER_
                 PLAN.md's M2 "dual dev server", js/packages/vite/src/
                 supervisor.mjs's `runDualDevServer` -- written and tested
                 5/5 well before anything spawned it). Implied by
                 --vite-args or --vite-dir. Spawns ONE child either way
                 (a small Node wrapper, js/packages/vite/bin/dual-dev.mjs,
                 running under this CLI's existing single-pid supervisor
                 model), so `hydronium dev`'s own liveness/stop handling
                 does not need to know two real servers are underneath it.
    --vite-args "<flags>"
                 Whitespace-split words appended after `vite` (no `dev`
                 subcommand -- running `vite` bare IS its dev server, see
                 js/examples/islands-tailwind's own `"dev": "vite"` npm
                 script). Same whitespace-splitting limitation as
                 --meteorite-args.
    --vite-dir <path>
                 Directory `vite dev` runs in (its cwd, so it finds the
                 right vite.config/node_modules). Default ".".
    --ballad     Run `ballad play partiture.lua` ONCE, to completion,
                 BEFORE any dev server starts -- a build step, not one of
                 runDualDevServer's supervised processes (that supervisor
                 brings every process down the moment ANY one exits, which
                 is right for two dev servers that are never supposed to
                 exit and wrong for a build that is supposed to exit 0).
                 A non-zero `ballad play` aborts `hydronium dev` before it
                 spawns anything.
    --ballad-args "<flags>"
                 Whitespace-split words replacing "partiture.lua" after
                 `ballad play`, e.g. --ballad-args "partiture.lua --jobs 4".
                 Implies --ballad.

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
-- JSON encoder for the dual dev-server wrapper's `--specs` argument (see
-- M.dual_dev_specs / M.dev's --vite branch below). Already a proven
-- dependency of this same package -- dev_log.lua uses it to encode every
-- line of .hydronium/dev.log -- so this adds no new package surface.
local json = require("hydronium_router.history.state")

local M = {}

M.VERSION = "0.2.0"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

M.USAGE = table.concat({
  "hydronium " .. M.VERSION,
  "",
  "Usage:",
  "  hydronium dev [--verbose] [--show-ips] [--fullscreen]",
  "                [--meteorite-args \"<flags>\"]",
  "                [--vite [--vite-args \"<flags>\"] [--vite-dir <path>]]",
  "                [--ballad [--ballad-args \"<flags>\"]]",
  "  hydronium build [--file <path>] [--plain | --ndjson] [--no-verify]",
  "                  [--vite [--vite-args \"<flags>\"] [--vite-dir <path>]]",
  "",
  "Commands:",
  "  dev            Run `meteorite dev` (optionally with `vite dev`) and",
  "                 render its dev-event stream.",
  "  build          Run the project's declared partiture.lua once, to",
  "                 completion, and exit. See `hydronium build --help`.",
  "  lab            Compatibility alias for `hydronium-lab dev`.",
  "  lab init       Install the standalone Lab tool and host adapter.",
  "",
  "Options:",
  "  --verbose      Show more rows in the events pane (display density only).",
  "  --show-ips     Show each request's remote address.",
  "  --fullscreen   Start in the fullscreen request-debug view.",
  "  --meteorite-args \"<flags>\"",
  "                 Arguments for the spawned `meteorite dev`, e.g.",
  "                 \"--mode hybrid_dev --backend fast_http\". Required in",
  "                 practice: `meteorite dev` has no defaults of its own.",
  "  --vite         Also start `vite dev`, merged into the same dev loop.",
  "  --vite-args \"<flags>\"",
  "                 Arguments for the spawned `vite` (implies --vite).",
  "  --vite-dir <path>",
  "                 Directory `vite dev` runs in. Default \".\".",
  "  --ballad       Run `ballad play partiture.lua` once before any dev",
  "                 server starts.",
  "  --ballad-args \"<flags>\"",
  "                 Arguments for that one-shot `ballad play` (implies",
  "                 --ballad).",
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

--- @param exit_code_table table<string, integer>
--- @return string
local function render_exit_codes(exit_code_table)
  local rows = {}
  for _, entry in ipairs(exit_code_table) do
    rows[#rows + 1] = string.format("  %d  %s", entry[1], entry[2])
  end
  return table.concat(rows, "\n")
end

M.BUILD_USAGE = table.concat({
  "hydronium build " .. M.VERSION,
  "",
  "Loads the project's declared partiture.lua, plans it (ballad's own",
  "Pipeline:plan()), executes it (ballad's own Pipeline:execute(), in-",
  "process -- no `ballad` subprocess is spawned), and exits. Nothing about",
  "what runs is inferred from a template name, directory layout, or which",
  "dependencies happen to be installed: no partiture.lua is a clear error,",
  "never a guess.",
  "",
  "Usage:",
  "  hydronium build [--file <path>] [--plain | --ndjson] [--no-verify]",
  "                  [--vite [--vite-args \"<flags>\"] [--vite-dir <path>]]",
  "",
  "Options:",
  "  --file <path>  Partiture file to load. Default: partiture.lua.",
  "  --plain        Line-oriented output, no cursor control -- safe for CI",
  "                 logs and pipes. Default without a TTY.",
  "  --ndjson       The build's event stream on stdout, one JSON object per",
  "                 line (the same events M0 writes to",
  "                 .ballad/runs/<run_id>/events.ndjson, plus one final",
  "                 build_finished/build_failed summary event).",
  "  --no-verify    Skip M3's isolated-chunk verification. Verification",
  "                 runs by default after a successful build.",
  "  --vite         Run `vite build` once, to completion, before verifying.",
  "                 A one-shot build, not a supervised dev process -- see",
  "                 `hydronium dev --vite` for the live-reload equivalent.",
  "  --vite-args \"<flags>\"",
  "                 Arguments for the one-shot `vite build` (implies --vite).",
  "  --vite-dir <path>",
  "                 Directory `vite build` runs in. Default \".\".",
  "  -h, --help     Print this help.",
  "",
  "Exit codes:",
  render_exit_codes({
    { 0, "success" },
    { 1, "usage error (bad flags)" },
    { 2, "the partiture failed to load or evaluate (missing file, syntax error, partiture construction error)" },
    { 3, "the pipeline failed while executing (a node raised)" },
    { 4, "verification failed (a produced chunk did not load/execute cleanly); skipped by --no-verify" },
    { 5, "the one-shot `vite build` failed (--vite only)" },
  }),
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
  if first == "build" then
    return M.parse_build_args(argv)
  end
  if first ~= "dev" then
    if first == "lab" then
      local parsed = { command = "lab", init = argv[2] == "init", host = "127.0.0.1", port = 6100 }
      local index = parsed.init and 3 or 2
      while index <= #argv do
        local token = argv[index]
        if token == "--no-open" then parsed.no_open = true
        elseif token == "--ci" then parsed.ci = true; parsed.no_open = true
        elseif token == "--host" or token == "--port" or token == "--config" or token == "--adapter" then
          local value = argv[index + 1]
          if not value then return nil, token .. " requires a value" end
          parsed[token:sub(3):gsub("%-", "_")] = token == "--port" and tonumber(value) or value
          index = index + 1
        elseif token:match("^%-%-host=") then parsed.host = token:match("=(.*)$")
        elseif token:match("^%-%-port=") then parsed.port = tonumber(token:match("=(.*)$"))
        elseif token:match("^%-%-config=") then parsed.config = token:match("=(.*)$")
        elseif token:match("^%-%-adapter=") then parsed.adapter = token:match("=(.*)$")
        else return nil, "unknown argument '" .. tostring(token) .. "' for `hydronium lab`" end
        index = index + 1
      end
      if not parsed.port or parsed.port < 1 or parsed.port > 65535 or parsed.port % 1 ~= 0 then return nil, "--port must be an integer from 1 to 65535" end
      return parsed
    end
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
    vite = false,
    vite_args = nil,
    vite_dir = nil,
    ballad = false,
    ballad_args = nil,
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
    elseif token == "--vite" then
      parsed.vite = true
    elseif token == "--vite-args" then
      local value = argv[index + 1]
      if value == nil then
        return nil, "--vite-args requires a value (e.g. --vite-args \"--port 5174\")"
      end
      parsed.vite_args = value
      parsed.vite = true
      index = index + 1
    elseif token:sub(1, 12) == "--vite-args=" then
      parsed.vite_args = token:sub(13)
      parsed.vite = true
    elseif token == "--vite-dir" then
      local value = argv[index + 1]
      if value == nil then
        return nil, "--vite-dir requires a value"
      end
      parsed.vite_dir = value
      index = index + 1
    elseif token:sub(1, 11) == "--vite-dir=" then
      parsed.vite_dir = token:sub(12)
    elseif token == "--ballad" then
      parsed.ballad = true
    elseif token == "--ballad-args" then
      local value = argv[index + 1]
      if value == nil then
        return nil, "--ballad-args requires a value (e.g. --ballad-args \"partiture.lua --jobs 4\")"
      end
      parsed.ballad_args = value
      parsed.ballad = true
      index = index + 1
    elseif token:sub(1, 14) == "--ballad-args=" then
      parsed.ballad_args = token:sub(15)
      parsed.ballad = true
    elseif token == "-h" or token == "--help" then
      return { command = "help" }
    else
      return nil, "unknown argument '" .. tostring(token) .. "' for `hydronium dev`"
    end
    index = index + 1
  end
  return parsed
end

--- @param argv string[] argv[1] == "build".
--- @return table|nil parsed, string|nil err
function M.parse_build_args(argv)
  local parsed = {
    command = "build",
    file = nil, -- default: build_runner.DEFAULT_PARTITURE ("partiture.lua")
    output = "ink", -- "ink" | "plain" | "ndjson"
    verify = true,
    vite = false,
    vite_args = nil,
    vite_dir = nil,
  }
  local index = 2
  while index <= #argv do
    local token = argv[index]
    if token == "--plain" then
      if parsed.output == "ndjson" then return nil, "--plain and --ndjson are mutually exclusive" end
      parsed.output = "plain"
    elseif token == "--ndjson" then
      if parsed.output == "plain" then return nil, "--plain and --ndjson are mutually exclusive" end
      parsed.output = "ndjson"
    elseif token == "--no-verify" then
      parsed.verify = false
    elseif token == "--file" then
      local value = argv[index + 1]
      if value == nil then return nil, "--file requires a value" end
      parsed.file = value
      index = index + 1
    elseif token:sub(1, 7) == "--file=" then
      parsed.file = token:sub(8)
    elseif token == "--vite" then
      parsed.vite = true
    elseif token == "--vite-args" then
      local value = argv[index + 1]
      if value == nil then
        return nil, "--vite-args requires a value (e.g. --vite-args \"--mode production\")"
      end
      parsed.vite_args = value
      parsed.vite = true
      index = index + 1
    elseif token:sub(1, 12) == "--vite-args=" then
      parsed.vite_args = token:sub(13)
      parsed.vite = true
    elseif token == "--vite-dir" then
      local value = argv[index + 1]
      if value == nil then return nil, "--vite-dir requires a value" end
      parsed.vite_dir = value
      index = index + 1
    elseif token:sub(1, 11) == "--vite-dir=" then
      parsed.vite_dir = token:sub(12)
    elseif token == "-h" or token == "--help" then
      return { command = "help", topic = "build" }
    else
      return nil, "unknown argument '" .. tostring(token) .. "' for `hydronium build`"
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

--- Words for the spawned `vite` dev server. No leading "dev" subcommand:
--- running `vite` bare IS its dev server (js/examples/islands-tailwind's
--- own `"dev": "vite"` npm script), matching how M.meteorite_argv already
--- spawns `meteorite dev` as two literal words rather than one.
--- @param parsed table From M.parse_args.
--- @return string[]
function M.vite_argv(parsed)
  local argv = {}
  if parsed and type(parsed.vite_args) == "string" then
    for word in parsed.vite_args:gmatch("%S+") do
      argv[#argv + 1] = word
    end
  end
  return argv
end

--- The `runDualDevServer` process-spec list (Meteorite, then Vite) for
--- js/packages/vite/bin/dual-dev.mjs. Pure data -- no I/O, no repo_root,
--- so a spec test can assert its shape without a real filesystem.
--- @param meteorite_argv string[] From M.meteorite_argv (argv[1] is the
---   program, e.g. "meteorite"; the rest are its own arguments).
--- @param parsed table From M.parse_args.
--- @return table[]
function M.dual_dev_specs(meteorite_argv, parsed)
  local meteorite_rest = {}
  for i = 2, #meteorite_argv do
    meteorite_rest[#meteorite_rest + 1] = meteorite_argv[i]
  end
  local vite_words = M.vite_argv(parsed)
  local vite_args = { "vite" }
  for _, word in ipairs(vite_words) do
    vite_args[#vite_args + 1] = word
  end
  return {
    { name = "meteorite", command = meteorite_argv[1], args = meteorite_rest },
    -- `npx`, not a bare `vite`: this must work from a project that
    -- declared vite as a local devDependency (js/examples/islands-tailwind
    -- does) without requiring it on PATH globally. npx resolves
    -- node_modules/.bin relative to `cwd`, which is `vite_dir` below.
    { name = "vite", command = "npx", args = vite_args, cwd = (parsed and parsed.vite_dir) or "." },
  }
end

--- The full argv for the ONE child `hydronium dev --vite` spawns: a small
--- Node wrapper (js/packages/vite/bin/dual-dev.mjs) that runs Meteorite
--- and Vite together via runDualDevServer. Kept separate from
--- M.dual_dev_specs so the JSON encoding (the part that actually needs
--- `json`, injected rather than hardcoded to `require`d module so a spec
--- can pass a fake) is the only impure step.
--- @param repo_root string This file's own repo root (see top-of-file `this_dir`/`repo_root`).
--- @param meteorite_argv string[]
--- @param parsed table
--- @param encode fun(value: any): string JSON encoder, e.g. `json.encode`.
--- @return string[]
function M.dual_dev_argv(repo_root, meteorite_argv, parsed, encode)
  local script = repo_root .. "/js/packages/vite/bin/dual-dev.mjs"
  return { "node", script, "--specs", encode(M.dual_dev_specs(meteorite_argv, parsed)) }
end

--- Compatibility command only. Lab discovery and host planning live in the
--- standalone hydronium/lab-cli package, keeping this developer console free
--- of renderer and web-host dependencies.
function M.lab_command(parsed)
  local parts = { "hydronium-lab", "dev", "--host", shell_quote(parsed.host or "127.0.0.1"),
    "--port", tostring(parsed.port or 6100) }
  if parsed.config then parts[#parts + 1], parts[#parts + 2] = "--config", shell_quote(parsed.config) end
  if parsed.adapter then parts[#parts + 1], parts[#parts + 2] = "--adapter", shell_quote(parsed.adapter) end
  if parsed.no_open then parts[#parts + 1] = "--no-open" end
  if parsed.ci then parts[#parts + 1] = "--ci" end
  return table.concat(parts, " ")
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

  -- Optional one-shot build step, run to completion BEFORE anything else
  -- spawns -- exactly what a person would type by hand first. Deliberately
  -- NOT one of runDualDevServer's supervised processes below: that
  -- supervisor brings every process down the instant ANY one exits, which
  -- is correct for two dev servers that must never exit and wrong for a
  -- build that is SUPPOSED to exit 0.
  local ballad_ok, ballad_cmd
  if parsed.ballad then
    local ballad_argv = { "ballad", "play" }
    for word in (parsed.ballad_args or "partiture.lua"):gmatch("%S+") do
      ballad_argv[#ballad_argv + 1] = word
    end
    local quoted = {}
    for i, word in ipairs(ballad_argv) do
      quoted[i] = dev_supervisor.shell_quote(word)
    end
    ballad_cmd = table.concat(quoted, " ")
    ballad_ok = dev_supervisor.exec_ok(os.execute, ballad_cmd)
    if not ballad_ok then
      io.stderr:write("hydronium dev: `" .. ballad_cmd .. "` failed; not starting the dev servers\n")
      return 1
    end
  end

  -- `--vite` spawns ONE child either way: a small Node wrapper
  -- (js/packages/vite/bin/dual-dev.mjs) that runs `runDualDevServer` over
  -- Meteorite + Vite together, so everything below this point -- liveness
  -- polling, SIGTERM/SIGKILL stop, the events.log tailer -- is unchanged
  -- and does not need to know two real servers are underneath it.
  local supervisor_argv = argv
  if parsed.vite then
    supervisor_argv = M.dual_dev_argv(repo_root, argv, parsed, json.encode)
  end

  local supervisor = dev_supervisor.new_supervisor({
    argv = supervisor_argv,
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
    vite = parsed.vite,
    ballad = parsed.ballad,
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

--- One line per newly-drained event, human-readable, no cursor control --
--- safe for CI logs and piping (M1's `--plain`).
--- @param events table[]
local function print_plain_events(events)
  for _, event in ipairs(events) do
    if event.kind == "node" then
      local label = (event.plugin or "?") .. "." .. (event.method or "?") .. " (" .. (event.id or "?") .. ")"
      if event.type == "task_started" then
        io.stdout:write("[build] started   " .. label .. "\n")
      elseif event.type == "task_finished" then
        io.stdout:write("[build] finished  " .. label
          .. string.format(" (%.1fms, %d asset(s))\n", event.duration_ms or 0, event.asset_count or 0))
      elseif event.type == "task_skipped" then
        io.stdout:write("[build] skipped   " .. label .. " (" .. (event.reason or "?") .. ")\n")
      elseif event.type == "task_failed" then
        io.stdout:write("[build] FAILED    " .. label .. ": " .. tostring(event.error) .. "\n")
      end
    elseif event.kind == "native" then
      local label = event.tool or event.id or "?"
      if event.type == "task_started" then
        io.stdout:write("[build] native started  " .. tostring(label) .. "\n")
      elseif event.type == "task_finished" or event.type == "task_incomplete" then
        io.stdout:write("[build] native finished " .. tostring(label) .. "\n")
      elseif event.type == "task_failed" then
        io.stdout:write("[build] native FAILED   " .. tostring(label) .. "\n")
      end
    end
  end
end

--- @param events table[]
--- @param encode fun(value: any): string
local function print_ndjson_events(events, encode)
  for _, event in ipairs(events) do
    io.stdout:write(encode(event) .. "\n")
  end
end

--- One-shot `vite build`, run to completion before the partiture (M5).
--- Symmetric with `hydronium dev`'s --vite/--vite-args/--vite-dir, but a
--- single child this function simply waits on -- NOT one of
--- runDualDevServer's supervised processes: that machinery is for two
--- live servers that must never exit; a build step is supposed to exit 0
--- and stop, so `hydronium build` does not copy any of the dev
--- supervisor's liveness/stop machinery for it.
--- @param parsed table From M.parse_build_args.
--- @return boolean ok
local function run_vite_build(parsed)
  local vite_args = { "vite", "build" }
  for word in (parsed.vite_args or ""):gmatch("%S+") do
    vite_args[#vite_args + 1] = word
  end
  local quoted = {}
  for i, word in ipairs(vite_args) do
    quoted[i] = dev_supervisor.shell_quote(word)
  end
  -- npx, not a bare `vite`: same reasoning as M.dual_dev_specs -- a project
  -- that declared vite as a local devDependency has no globally installed
  -- `vite` binary, and npx resolves node_modules/.bin relative to cwd.
  local cmd = "cd " .. dev_supervisor.shell_quote(parsed.vite_dir or ".") .. " && npx "
    .. table.concat(quoted, " ")
  io.stdout:write("hydronium build: running `" .. table.concat(vite_args, " ") .. "` in "
    .. (parsed.vite_dir or ".") .. "\n")
  return dev_supervisor.exec_ok(os.execute, cmd)
end

--- @param parsed table From M.parse_build_args.
--- @return integer exit code
function M.build(parsed)
  local build_runner = require("build_runner")
  local file = parsed.file or build_runner.DEFAULT_PARTITURE

  -- Explicit --plain/--ndjson always win; otherwise the Ink view (M2).
  -- hydronium_ink.render itself already detects a non-interactive stdin
  -- (ink/src/hydronium_ink/render.lua's own `ffi.C.isatty(0)` check) and
  -- degrades to plain `io.write` with no raw mode/cursor control there --
  -- `hydronium build` does not need a second TTY check of its own on top
  -- of that.
  local output = parsed.output
  -- --ndjson's stdout contract is "the event stream, one object per line"
  -- ONLY -- every human-readable status line this function would otherwise
  -- print to stdout goes to stderr instead, so `hydronium build --ndjson |
  -- some-json-consumer` never has to filter out prose.
  local say = (output == "ndjson")
    and function(msg) io.stderr:write(msg .. "\n") end
    or function(msg) io.stdout:write(msg .. "\n") end
  local json = require("hydronium_router.history.state")
  local function say_ndjson_summary(event)
    if output == "ndjson" then
      io.stdout:write(json.encode(event) .. "\n")
    end
  end

  if parsed.vite then
    if not run_vite_build(parsed) then
      io.stderr:write("hydronium build: `vite build` failed; not running the partiture\n")
      say_ndjson_summary({ type = "build_failed", stage = "vite" })
      return build_runner.EXIT_VITE_FAILED
    end
  end

  local p, load_err = build_runner.load(file, 1, {})
  if not p then
    io.stderr:write("hydronium build: " .. tostring(load_err) .. "\n")
    say_ndjson_summary({ type = "build_failed", stage = "load", error = tostring(load_err) })
    return build_runner.EXIT_PARTITURE_ERROR
  end

  local status, result, sink_results
  if output == "ink" then
    local build_view = require("ui.build_view")
    status, result, sink_results = build_view.run(p, build_runner)
  else
    local runner = build_runner.new_runner(p)
    say("hydronium build: " .. #runner.plan.order .. " step(s) planned")
    status, result = build_runner.drain(runner, function(events)
      if output == "ndjson" then
        print_ndjson_events(events, json.encode)
      else
        print_plain_events(events)
      end
    end)
    sink_results = status == "done" and result or nil
  end

  if status == "error" then
    local message = require("ballad.diagnostic").is(result) and require("ballad.diagnostic").render(result)
      or tostring(result)
    io.stderr:write("hydronium build: pipeline failed: " .. message .. "\n")
    say_ndjson_summary({ type = "build_failed", stage = "execute", error = message })
    return build_runner.EXIT_PIPELINE_FAILED
  end

  if parsed.verify then
    local build_verify = require("build_verify")
    local ok, failures, checked = build_verify.verify(p)
    if checked > 0 then
      say("hydronium build: verified " .. checked .. " chunk(s) in a fresh isolated Lua state")
    end
    if not ok then
      for _, failure in ipairs(failures) do
        io.stderr:write("hydronium build: VERIFY FAILED " .. failure.chunk.output_path .. "\n"
          .. failure.output .. "\n")
      end
      say_ndjson_summary({ type = "build_failed", stage = "verify", failed_chunks = #failures })
      return build_runner.EXIT_VERIFY_FAILED
    end
  end

  say("hydronium build: done (" .. #sink_results .. " sink(s))")
  say_ndjson_summary({ type = "build_finished", sinks = #sink_results })
  return build_runner.EXIT_OK
end

--- @param argv string[]
--- @return integer exit code
function M.main(argv)
  local parsed, err = M.parse_args(argv)
  if not parsed then
    local usage = argv[1] == "build" and M.BUILD_USAGE or M.USAGE
    io.stderr:write("hydronium: " .. tostring(err) .. "\n\n" .. usage .. "\n")
    return 1
  end
  if parsed.command == "help" then
    io.stdout:write((parsed.topic == "build" and M.BUILD_USAGE or M.USAGE) .. "\n")
    return 0
  end
  if parsed.command == "version" then
    io.stdout:write("hydronium " .. M.VERSION .. "\n")
    return 0
  end
  if parsed.command == "build" then
    return M.build(parsed)
  end
  if parsed.command == "lab" then
    if parsed.init then
      local commands = {
        "moon add --dev --no-sync hydronium/lab hydronium/ink-lab hydronium/meteorite",
        "moon add --tool --no-sync hydronium/lab-cli moonstone/meteorite",
        "moon manifest script set lab --command 'moon exec --dev -- hydronium-lab dev'",
        "moon sync",
      }
      for _, command in ipairs(commands) do
        local ok, _, code = os.execute(command)
        if not (ok == true or ok == 0) then
          io.stderr:write("hydronium lab init: command failed: " .. command .. " (" .. tostring(code or ok) .. ")\n")
          return 1
        end
      end
      io.stdout:write("Hydronium Lab added. Create a *.stories.lua or *.stories.luax file, then run `moon run lab`.\n")
      return 0
    end
    local ok, why, code = os.execute(M.lab_command(parsed))
    if not (ok == true or ok == 0) then
      io.stderr:write("hydronium lab: standalone `hydronium-lab` failed (is hydronium/lab-cli installed?): "
        .. tostring(code or why or ok) .. "\n")
      return 1
    end
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
