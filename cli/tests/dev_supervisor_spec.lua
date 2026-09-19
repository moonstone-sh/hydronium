--[[
  hydronium-cli dev_supervisor -- offset tailing of
  `.meteorite/dev/events.log`, and the shell plumbing around the
  `meteorite dev` child.

  The tailing specs use a REAL temp file written by real `io.open`/
  `f:write` calls, appended to between polls exactly the way meteorite
  appends to its own file -- that is the whole behavior under test, and a
  fake file object would only prove the fake works. The child-process
  specs inject `popen`/`os.execute` stand-ins instead: spawning a real
  `meteorite dev` here would need meteorite installed, a project to build,
  and would leave a server running after the suite.
--]]

local runner = require("tests.runner")
local describe, it, assert, after_each = runner.describe, runner.it, runner.assert, runner.after_each

local dev_supervisor = require("dev_supervisor")

local temp_paths = {}

local function temp_path(name)
  local path = os.tmpname()
  os.remove(path)
  path = path .. "-" .. name
  temp_paths[#temp_paths + 1] = path
  return path
end

--- The runner only collects before_each/after_each hooks registered at
--- describe level 1 or deeper (see tests/runner.lua's M.it, which walks
--- `1..#describe_stack`), so this is registered inside each describe
--- block below rather than once at file scope, where it would silently
--- never run.
local function remove_temp_files()
  for _, path in ipairs(temp_paths) do
    os.remove(path)
  end
  temp_paths = {}
end

--- Deliberately not `assert(io.open(...))`: this runner replaces the
--- global `assert` with its own assertion TABLE (see tests/runner.lua's
--- `_G.assert = M.assert`), so calling it here would fail with "attempt
--- to call a table value" instead of reporting the real open failure.
local function write_file(path, contents, mode)
  local file, err = io.open(path, mode or "w")
  if not file then
    error("could not open " .. tostring(path) .. ": " .. tostring(err), 2)
  end
  file:write(contents)
  file:close()
end

local function append(path, contents)
  write_file(path, contents, "a")
end

local function request_line(ts, path)
  return '{"v":1,"ts":' .. ts .. ',"source":"server","kind":"request","method":"GET",'
    .. '"path":"' .. path .. '","status":200,"duration_ms":5,"remote_addr":null}\n'
end

describe("hydronium-cli dev_supervisor -- shell helpers", function()
  it("single-quotes a path containing a quote safely", function()
    assert.equal(dev_supervisor.shell_quote("plain"), "'plain'")
    assert.equal(dev_supervisor.shell_quote("it's"), "'it'\\''s'")
  end)

  it("reads os.execute's 5.1 and 5.2+ return shapes the same way", function()
    assert.truthy(dev_supervisor.exec_ok(function() return 0 end, "x"))
    assert.falsy(dev_supervisor.exec_ok(function() return 1 end, "x"))
    assert.truthy(dev_supervisor.exec_ok(function() return true, "exit", 0 end, "x"))
    assert.falsy(dev_supervisor.exec_ok(function() return nil, "exit", 1 end, "x"))
  end)
end)

describe("hydronium-cli dev_supervisor -- tailer", function()
  after_each(remove_temp_files)

  it("returns nothing, and does not error, while the file does not exist", function()
    local tailer = dev_supervisor.new_tailer(temp_path("absent.log"))
    assert.same(tailer:poll(), {})
    assert.truthy(tailer.missing)
    assert.same(tailer:poll(), {})
  end)

  it("reads a file that appears only after the first few polls", function()
    local path = temp_path("late.log")
    local tailer = dev_supervisor.new_tailer(path)
    assert.same(tailer:poll(), {})
    write_file(path, request_line(1000, "/home"))
    local lines = tailer:poll()
    assert.equal(#lines, 1)
    assert.falsy(tailer.missing)
  end)

  it("reads only the bytes appended since the previous poll", function()
    local path = temp_path("grow.log")
    write_file(path, request_line(1000, "/a"))
    local tailer = dev_supervisor.new_tailer(path)

    local first = tailer:poll()
    assert.equal(#first, 1)
    assert.truthy(first[1]:find("/a", 1, true))

    -- Nothing new: no repeated lines.
    assert.same(tailer:poll(), {})

    append(path, request_line(1100, "/b") .. request_line(1200, "/c"))
    local second = tailer:poll()
    assert.equal(#second, 2)
    assert.truthy(second[1]:find("/b", 1, true))
    assert.truthy(second[2]:find("/c", 1, true))
    assert.same(tailer:poll(), {})
  end)

  it("holds a line read mid-write until its newline arrives", function()
    -- The real concurrency case: meteorite is appending while we read.
    local path = temp_path("partial.log")
    local full = request_line(1000, "/home")
    write_file(path, full:sub(1, 20))

    local tailer = dev_supervisor.new_tailer(path)
    assert.same(tailer:poll(), {}, "a fragment with no newline is not a line yet")
    assert.equal(tailer.pending, full:sub(1, 20))

    append(path, full:sub(21))
    local lines = tailer:poll()
    assert.equal(#lines, 1)
    assert.equal(lines[1], full:sub(1, #full - 1))
    assert.equal(tailer.pending, "")
  end)

  it("strips a CRLF writer's carriage return", function()
    local path = temp_path("crlf.log")
    write_file(path, '{"v":1,"ts":1,"source":"cli","kind":"reload","ok":true}\r\n')
    local lines = dev_supervisor.new_tailer(path):poll()
    assert.equal(lines[1]:sub(-1), "}")
  end)

  it("recovers from truncation by re-reading from byte zero", function()
    local path = temp_path("truncate.log")
    write_file(path, request_line(1000, "/a") .. request_line(1100, "/b"))
    local tailer = dev_supervisor.new_tailer(path)
    assert.equal(#tailer:poll(), 2)
    assert.truthy(tailer.offset > 0)

    -- `> file`: same inode, size back to zero, then one fresh line.
    write_file(path, request_line(2000, "/after-truncate"))

    local lines = tailer:poll()
    assert.equal(#lines, 1, "a truncated file must be re-read from the top, not skipped")
    assert.truthy(lines[1]:find("/after-truncate", 1, true))
    assert.equal(tailer.truncations, 1)
  end)

  it("drops a stale offset when the file is deleted and recreated", function()
    local path = temp_path("rotate.log")
    write_file(path, request_line(1000, "/a") .. request_line(1100, "/b"))
    local tailer = dev_supervisor.new_tailer(path)
    assert.equal(#tailer:poll(), 2)

    os.remove(path)
    assert.same(tailer:poll(), {})
    assert.truthy(tailer.missing)

    write_file(path, request_line(2000, "/fresh"))
    local lines = tailer:poll()
    assert.equal(#lines, 1)
    assert.truthy(lines[1]:find("/fresh", 1, true))
  end)

  it("seek_to_end skips a previous session's events", function()
    local path = temp_path("previous.log")
    write_file(path, request_line(1000, "/old") .. request_line(1100, "/older"))
    local tailer = dev_supervisor.new_tailer(path)
    tailer:seek_to_end()
    assert.same(tailer:poll(), {})

    append(path, request_line(2000, "/new"))
    local lines = tailer:poll()
    assert.equal(#lines, 1)
    assert.truthy(lines[1]:find("/new", 1, true))
  end)

  it("seek_to_end is safe when the file does not exist yet", function()
    local path = temp_path("nothing-yet.log")
    local tailer = dev_supervisor.new_tailer(path)
    tailer:seek_to_end()
    assert.truthy(tailer.missing)
    write_file(path, request_line(1000, "/home"))
    assert.equal(#tailer:poll(), 1)
  end)

  it("requires a path", function()
    assert.has_error(function() dev_supervisor.new_tailer(nil) end, "file path is required")
  end)
end)

describe("hydronium-cli dev_supervisor -- child process", function()
  after_each(remove_temp_files)

  --- Captures the shell line without running anything.
  local function fake_popen(captured, pid_text)
    return function(command)
      captured[#captured + 1] = command
      return {
        read = function() return pid_text end,
        close = function() end,
      }
    end
  end

  it("backgrounds the command, redirects its output, and reads back its pid", function()
    local captured = {}
    local pid = dev_supervisor.spawn_detached({ "meteorite", "dev" }, {
      output_path = ".hydronium/meteorite-dev.out",
      popen = fake_popen(captured, "4242"),
    })
    assert.equal(pid, 4242)
    local command = captured[1]
    assert.truthy(command:find('CLINGY_OWNER_PID="$PPID"', 1, true))
    assert.truthy(command:find("'meteorite' 'dev'", 1, true))
    assert.truthy(command:find(">> '.hydronium/meteorite-dev.out' 2>&1", 1, true))
    -- The child must not be able to eat a keystroke meant for the UI:
    -- this CLI owns the real stdin in raw mode.
    assert.truthy(command:find("< /dev/null", 1, true))
    assert.truthy(command:find("& echo $!", 1, true))
  end)

  it("reports an error rather than a pid when the shell prints nothing", function()
    local pid, err = dev_supervisor.spawn_detached({ "meteorite", "dev" }, {
      popen = fake_popen({}, nil),
    })
    assert.is_nil(pid)
    assert.equal(err, "child started but did not report a pid")
  end)

  it("reports an error when a shell cannot be started at all", function()
    local pid, err = dev_supervisor.spawn_detached({ "meteorite", "dev" }, {
      popen = function() return nil, "no shell" end,
    })
    assert.is_nil(pid)
    assert.equal(err, "no shell")
  end)

  it("probes liveness with kill -0 and never claims a nil pid is alive", function()
    local seen = {}
    local exec = function(command)
      seen[#seen + 1] = command
      return 0
    end
    assert.truthy(dev_supervisor.is_alive(4242, exec))
    assert.truthy(seen[1]:find("kill -0 4242", 1, true))
    assert.falsy(dev_supervisor.is_alive(nil, exec))
    assert.falsy(dev_supervisor.is_alive(4242, function() return 1 end))
  end)
end)

describe("hydronium-cli dev_supervisor -- supervisor", function()
  after_each(remove_temp_files)

  it("tails without spawning when spawn is false", function()
    local path = temp_path("no-spawn.log")
    local supervisor = dev_supervisor.new_supervisor({ events_path = path, spawn = false })
    assert.is_nil(supervisor:start())
    assert.is_nil(supervisor.pid)
    assert.truthy(supervisor:events_missing())

    write_file(path, request_line(1000, "/home"))
    assert.equal(#supervisor:poll(), 1)
    assert.falsy(supervisor:events_missing())
    assert.falsy(supervisor:is_alive())
  end)

  it("spawns through the injected popen and remembers the pid", function()
    local commands = {}
    local supervisor = dev_supervisor.new_supervisor({
      argv = { "meteorite", "dev" },
      events_path = temp_path("spawned.log"),
      child_output_path = temp_path("child.out"),
      popen = function(command)
        commands[#commands + 1] = command
        return { read = function() return "777" end, close = function() end }
      end,
      exec = function() return 0 end,
    })
    assert.equal(supervisor:start(), 777)
    assert.equal(supervisor.pid, 777)
    assert.truthy(commands[1]:find("'meteorite' 'dev'", 1, true))
  end)

  it("escalates TERM to KILL when the child will not die, and is idempotent", function()
    local signals = {}
    local supervisor = dev_supervisor.new_supervisor({
      events_path = temp_path("stubborn.log"),
      popen = function() return { read = function() return "999" end, close = function() end } end,
      exec = function(command)
        signals[#signals + 1] = command
        -- kill -0 keeps succeeding: the child never exits.
        return 0
      end,
    })
    supervisor:start()
    supervisor:stop(2)

    local joined = table.concat(signals, "\n")
    assert.truthy(joined:find("kill -TERM 999", 1, true))
    assert.truthy(joined:find("kill -KILL 999", 1, true))

    local before = #signals
    supervisor:stop(2)
    assert.equal(#signals, before, "stop() must be idempotent")
  end)

  it("stops after TERM when the child does exit", function()
    local signals = {}
    local alive = true
    local supervisor = dev_supervisor.new_supervisor({
      events_path = temp_path("obedient.log"),
      popen = function() return { read = function() return "888" end, close = function() end } end,
      exec = function(command)
        signals[#signals + 1] = command
        if command:find("kill -TERM", 1, true) then
          alive = false
          return 0
        end
        if command:find("kill -0", 1, true) then
          return alive and 0 or 1
        end
        return 0
      end,
    })
    supervisor:start()
    supervisor:stop(10)
    assert.falsy(table.concat(signals, "\n"):find("kill -KILL", 1, true))
  end)
end)

describe("hydronium-cli dev_supervisor -- tailer feeding event_model", function()
  after_each(remove_temp_files)

  it("turns a real file's growth into collapsed display rows, skipping garbage", function()
    -- The actual end-to-end shape of one `onTick`, minus the terminal.
    local event_model = require("event_model")
    local path = temp_path("combined.log")
    write_file(path, request_line(1000, "/home"))

    local tailer = dev_supervisor.new_tailer(path)
    local buffer = event_model.new_buffer()

    for _, line in ipairs(tailer:poll()) do
      buffer:push_line(line)
    end
    assert.same(buffer:lines(), { "GET /home \194\183 5ms" })

    append(path, request_line(1100, "/home") .. "{ half-written\n" .. request_line(1200, "/home"))
    for _, line in ipairs(tailer:poll()) do
      buffer:push_line(line)
    end
    assert.same(buffer:lines(), { "GET /home \194\183 5ms x3" },
      "the malformed line is skipped, and does not break the run of collapsible requests")
  end)
end)
