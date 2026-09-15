--[[
  hydronium-cli dev_supervisor -- owns the `meteorite dev` child process
  and tails the dev-event file that child writes.

  TWO INDEPENDENT PIECES, on purpose:

    * `Tailer`  -- byte-offset tailing of `.meteorite/dev/events.log`.
      Touches no process at all, so cli/tests/dev_supervisor_spec.lua can
      drive it against a hand-written temp file (including truncation)
      with no meteorite anywhere.
    * `Supervisor` -- spawn + liveness + stop, wrapped around a Tailer.

  PROCESS MODEL. `meteorite`'s own src/cli/dev.lua supervises its server
  through Clingy and a PID file; this CLI is a separate OUTER process and
  deliberately does not reach into that -- it just needs one backgrounded
  child and its pid. The mechanism is therefore the plainest thing that
  actually works from stock Lua with no extra dependency: `io.popen` on a
  shell line that backgrounds the command and echoes `$!`.

      meteorite dev ... >> <out> 2>&1 < /dev/null & echo $!

  The popen'd shell exits immediately after printing the pid; the child is
  reparented to init and keeps running, which is exactly what we want --
  a blocking `os.execute` would never return, and a plain `io.popen`
  handle read in the render loop would block the UI. The cost, stated: no
  SIGCHLD, so liveness is polled with `kill -0` rather than observed.
  Anything more (real fork/exec via FFI, a pty) buys nothing here and
  would have to be carried on every platform.

  TAILING. Three real conditions the file is in, all handled:
    * not there yet -- meteorite has not started, or is an older build
      with no emitter at all. `poll()` returns no lines and sets
      `missing`; it never errors. The UI shows "server running" rather
      than a failure (see ui/app.lua).
    * growing -- only the bytes past `offset` are read, each poll.
    * truncated or rotated -- detected as `size < offset`; offset (and any
      buffered partial line) resets to 0 and the file is re-read from the
      top, which is the correct recovery for both `> file` truncation and
      a delete/recreate.

  A line may also be read MID-WRITE, since another process is appending
  concurrently: only text up to the last newline is emitted as lines, and
  the trailing fragment is held in `pending` until its newline arrives.
--]]

local M = {}

--- Where meteorite writes its dev-event stream, relative to the project
--- root. Mirrored from the plan's meteorite half (src/cli/dev_command.lua
--- computes exactly this path); not configurable there, so not guessed at
--- here either.
M.DEFAULT_EVENTS_PATH = ".meteorite/dev/events.log"

--- A partial trailing line bigger than this is discarded rather than
--- buffered forever -- the real dev-event lines are a few hundred bytes,
--- so anything at this scale means the file is not what we think it is.
M.MAX_PENDING_BYTES = 1024 * 1024

-- ---------------------------------------------------------------------
-- Shell helpers
-- ---------------------------------------------------------------------

--- POSIX single-quote quoting: safe for every byte except that a literal
--- `'` has to close, escape, and reopen the quoted run.
--- @param s string
--- @return string
function M.shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- `os.execute` reports success differently on 5.1 (a raw status number)
--- and 5.2+ (ok, "exit", code). Normalize both to a boolean.
--- @param exec fun(cmd: string): any, any, any
--- @param cmd string
--- @return boolean
function M.exec_ok(exec, cmd)
  local a, _, c = exec(cmd)
  if type(a) == "number" then
    return a == 0
  end
  if a == true then
    return c == nil or c == 0
  end
  return false
end

--- `mkdir -p`, used for the directory holding a spawned child's output.
--- @param dir string
--- @param exec? function
function M.ensure_dir(dir, exec)
  exec = exec or os.execute
  M.exec_ok(exec, "mkdir -p " .. M.shell_quote(dir))
end

-- ---------------------------------------------------------------------
-- Tailer
-- ---------------------------------------------------------------------

local Tailer = {}
Tailer.__index = Tailer
M.Tailer = Tailer

--- @class hydronium_cli.TailerOptions
--- @field open? fun(path: string, mode: string): file*|nil Injectable for tests; defaults to io.open.

--- @param path string
--- @param opts? hydronium_cli.TailerOptions
--- @return table
function M.new_tailer(path, opts)
  opts = opts or {}
  if type(path) ~= "string" or path == "" then
    error("dev_supervisor.new_tailer: a file path is required", 2)
  end
  return setmetatable({
    path = path,
    open = opts.open or io.open,
    offset = 0,
    pending = "",
    missing = true,
    seen_file = false,
    truncations = 0,
    dropped_bytes = 0,
  }, Tailer)
end

--- Reads whatever has been appended since the last call.
--- @return string[] lines Complete lines only, in file order. Empty when there is nothing new (or no file yet).
function Tailer:poll()
  local file = self.open(self.path, "rb")
  if not file then
    -- Not an error: meteorite may not have started, may not have created
    -- the directory yet, or may be an older build with no emitter. If a
    -- file we HAD been reading has gone away, drop our position -- a
    -- replacement starts from byte 0.
    if self.seen_file then
      self.offset = 0
      self.pending = ""
      self.seen_file = false
    end
    self.missing = true
    return {}
  end

  self.missing = false
  self.seen_file = true

  local size = file:seek("end") or 0
  if size < self.offset then
    -- Truncated (`> file`) or rotated out from under us.
    self.offset = 0
    self.pending = ""
    self.truncations = self.truncations + 1
  end

  if size == self.offset then
    file:close()
    return {}
  end

  file:seek("set", self.offset)
  local chunk = file:read(size - self.offset) or ""
  file:close()

  -- Trust the bytes actually returned, not the size we asked for.
  self.offset = self.offset + #chunk

  local buffer = self.pending .. chunk
  local lines = {}
  local start = 1
  while true do
    local newline = buffer:find("\n", start, true)
    if not newline then
      break
    end
    local line = buffer:sub(start, newline - 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    lines[#lines + 1] = line
    start = newline + 1
  end

  self.pending = buffer:sub(start)
  if #self.pending > M.MAX_PENDING_BYTES then
    self.dropped_bytes = self.dropped_bytes + #self.pending
    self.pending = ""
  end

  return lines
end

--- Positions the tailer at the current end of the file without emitting
--- anything, so an existing log from a previous run is not replayed.
--- Safe to call when the file does not exist yet.
function Tailer:seek_to_end()
  local file = self.open(self.path, "rb")
  if not file then
    self.missing = true
    return
  end
  self.offset = file:seek("end") or 0
  file:close()
  self.pending = ""
  self.missing = false
  self.seen_file = true
end

-- ---------------------------------------------------------------------
-- Child process
-- ---------------------------------------------------------------------

--- Starts `argv` in the background and returns its pid.
--- @param argv string[] Program plus arguments, unquoted.
--- @param opts? { output_path?: string, popen?: function }
--- @return integer|nil pid, string|nil err
function M.spawn_detached(argv, opts)
  opts = opts or {}
  if type(argv) ~= "table" or #argv == 0 then
    error("dev_supervisor.spawn_detached: argv must be a non-empty array", 2)
  end

  local quoted = {}
  for i, word in ipairs(argv) do
    quoted[i] = M.shell_quote(word)
  end
  -- Strip LUA_CPATH before the child inherits it. This process is a
  -- LuaJIT 5.1 program; a parent moon-exec context that put this CLI on
  -- PATH may well have exported a 5.1-flavored LUA_CPATH for its own
  -- ABI. LUA_PATH (pure Lua source, no ABI) is harmless and in practice
  -- load-bearing -- it is how a project's own tool dependencies (e.g.
  -- Clingy) end up resolvable by a spawned `meteorite dev`, which does
  -- not otherwise add its own package's env to its search path. LUA_
  -- CPATH is different: it can point a *different* Lua (meteorite's own
  -- dev.lua runs under plain Lua, not LuaJIT) at a native (.so/.dylib)
  -- module built for the wrong ABI, which fails or -- worse -- misloads
  -- rather than falling back to a pure-Lua alternative.
  local line = "env -u LUA_CPATH " .. table.concat(quoted, " ")

  if opts.output_path then
    line = line .. " >> " .. M.shell_quote(opts.output_path) .. " 2>&1"
  else
    line = line .. " >/dev/null 2>&1"
  end
  -- `< /dev/null` matters: this CLI owns the real stdin (ink's render()
  -- puts it in raw mode), so the child must never be able to consume a
  -- keystroke meant for the UI.
  line = line .. " < /dev/null & echo $!"

  local popen = opts.popen or io.popen
  local pipe, open_err = popen(line, "r")
  if not pipe then
    return nil, tostring(open_err or "could not start a shell")
  end
  local first = pipe:read("*l")
  pipe:close()

  local pid = tonumber(first or "")
  if not pid then
    return nil, "child started but did not report a pid"
  end
  return math.floor(pid)
end

--- @param pid integer|nil
--- @param exec? function
--- @return boolean
function M.is_alive(pid, exec)
  if not pid then
    return false
  end
  return M.exec_ok(exec or os.execute, "kill -0 " .. tostring(pid) .. " >/dev/null 2>&1")
end

--- @param pid integer|nil
--- @param signal? string Default "TERM".
--- @param exec? function
function M.signal_pid(pid, signal, exec)
  if not pid then
    return false
  end
  return M.exec_ok(
    exec or os.execute,
    "kill -" .. (signal or "TERM") .. " " .. tostring(pid) .. " >/dev/null 2>&1"
  )
end

-- ---------------------------------------------------------------------
-- Supervisor
-- ---------------------------------------------------------------------

local Supervisor = {}
Supervisor.__index = Supervisor
M.Supervisor = Supervisor

--- @class hydronium_cli.SupervisorOptions
--- @field argv? string[] Defaults to `{ "meteorite", "dev" }`.
--- @field events_path? string Defaults to M.DEFAULT_EVENTS_PATH.
--- @field child_output_path? string Where the child's own stdout/stderr go. Defaults to `.hydronium/meteorite-dev.out` -- it must not land on this CLI's terminal, which ink is painting.
--- @field spawn? boolean Default true. False builds a supervisor that only tails (used to point at a pre-seeded events.log without a meteorite on PATH).
--- @field popen? function Injectable.
--- @field exec? function Injectable.
--- @field open? function Injectable (passed through to the Tailer).

--- @param opts? hydronium_cli.SupervisorOptions
--- @return table
function M.new_supervisor(opts)
  opts = opts or {}
  return setmetatable({
    argv = opts.argv or { "meteorite", "dev" },
    events_path = opts.events_path or M.DEFAULT_EVENTS_PATH,
    child_output_path = opts.child_output_path or ".hydronium/meteorite-dev.out",
    should_spawn = opts.spawn ~= false,
    popen = opts.popen or io.popen,
    exec = opts.exec or os.execute,
    tailer = M.new_tailer(opts.events_path or M.DEFAULT_EVENTS_PATH, { open = opts.open }),
    pid = nil,
    spawn_error = nil,
    stopped = false,
  }, Supervisor)
end

--- @return integer|nil pid, string|nil err
function Supervisor:start()
  if not self.should_spawn then
    return nil, nil
  end
  local dir = self.child_output_path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" then
    M.ensure_dir(dir, self.exec)
  end
  local pid, err = M.spawn_detached(self.argv, {
    output_path = self.child_output_path,
    popen = self.popen,
  })
  self.pid = pid
  self.spawn_error = err
  return pid, err
end

--- @return string[] lines
function Supervisor:poll()
  return self.tailer:poll()
end

--- True while the events file has never appeared. Meaningful to the UI:
--- the server may well be up and serving, just without an emitter.
--- @return boolean
function Supervisor:events_missing()
  return self.tailer.missing
end

--- @return boolean
function Supervisor:is_alive()
  if not self.should_spawn then
    return false
  end
  return M.is_alive(self.pid, self.exec)
end

--- SIGTERM, then SIGKILL after `grace_polls` liveness checks. Idempotent.
--- @param grace_polls? integer Default 20 (~2s at the caller's own pacing).
function Supervisor:stop(grace_polls)
  if self.stopped or not self.pid then
    self.stopped = true
    return
  end
  self.stopped = true
  M.signal_pid(self.pid, "TERM", self.exec)
  for _ = 1, (grace_polls or 20) do
    if not M.is_alive(self.pid, self.exec) then
      return
    end
    M.exec_ok(self.exec, "sleep 0.1")
  end
  M.signal_pid(self.pid, "KILL", self.exec)
end

return M
