--[[
  Hydronium Ink demo -- a real, live terminal counter app.

  NOT part of `luajit tests/runner.lua` (that suite always injects a
  byte-capturing writer -- see tests/host/terminal_spec.lua -- so it
  never actually proves real stdout/ANSI behavior). This script is meant
  to be run by a human (or captured via a pty-wrapping tool -- see
  below) to see hydronium.host.terminal drive REAL stdout:

    luajit examples/ink_demo/run.lua

  Ctrl-C to stop (it loops until killed or until TICKS elapses).

  Because this agent has no way to interactively watch a live terminal,
  the actual verification evidence for this demo is: running it through
  a pty-wrapping tool (plain `> file 2>&1` redirection can make some
  programs/terminal libraries detect "not a tty" and change behavior --
  not applicable to this module, which never queries isatty(), but using
  a real pty is still the honest way to capture "what a real terminal
  session would have received") for a couple of seconds, then inspecting
  the raw captured bytes with `cat -v` / `xxd` to confirm they are real,
  well-formed ANSI (cursor moves, SGR codes, real box-drawing UTF-8), not
  garbage or literal escape characters:

    script -q /dev/null luajit examples/ink_demo/run.lua > /tmp/ink_output.txt 2>&1 &
    sleep 2 && kill %1
    cat -v /tmp/ink_output.txt | head -80

  See docs/HYDRONIUM_INK_TERMINAL_HOST.md for the actual captured
  evidence from running exactly this.
--]]

package.path = "core/src/?.lua;core/src/?/init.lua;ink/src/?.lua;ink/src/?/init.lua;./?.lua;./?/init.lua;" .. package.path

-- Real terminal UIs need every frame to reach the terminal immediately,
-- not sit in C stdio's default full-block buffering (which only flushes
-- once several KB have accumulated or the process exits normally --
-- confirmed the hard way while capturing this demo's own evidence: a
-- `kill`ed process loses whatever was still sitting in that buffer,
-- since SIGTERM does not run libc's atexit-flush). Unbuffered mode makes
-- every host.flush() -> writeFn() call a real, immediate write(2), which
-- is both correct product behavior for a live TUI and what makes this
-- demo's captured-output evidence trustworthy regardless of exactly
-- when the process is stopped.
io.stdout:setvbuf("no")

local hydronium = require("hydronium")
local reconcilerModule = require("hydronium.core.reconciler")
local terminalHostModule = require("hydronium_ink.host.terminal")
local ink = require("hydronium_ink")

-- Real default host: writeFn defaults to io.write, i.e. actual stdout --
-- the one thing this demo exists to prove, as opposed to
-- terminal_spec.lua's byte-capturing host.
local host = terminalHostModule.createTerminalHost()
local root = host.getRoot()
local reconciler = reconcilerModule.Reconciler.new(host)

local count, setCount = hydronium.signal(0)

local function App()
  -- Setup-once/render-many closure component (see
  -- tests/core/component_spec.lua) -- ordinary Hydronium usage, nothing
  -- terminal-specific about the component itself.
  return function()
    return hydronium.h(ink.Box, { borderStyle = "single", flexDirection = "column", paddingX = 1 },
      hydronium.h(ink.Text, { bold = true }, "Hydronium Ink demo"),
      hydronium.h(ink.Text, { color = "cyan" }, "Count: " .. tostring(count())),
      hydronium.h(ink.Text, { color = "gray" }, "(Ctrl-C to stop)")
    )
  end
end

reconciler:mount(hydronium.h(App), root)
host.flush() -- see host/terminal.lua's "REPAINT STRATEGY" doc comment: the
              -- host contract has no commit-end hook, so this host's own
              -- (beyond-the-7-method) API requires an explicit flush after
              -- each mount/update to actually paint.

local ticks = tonumber(arg and arg[1]) or 1000000
for i = 1, ticks do
  -- No external sleep dependency inside src/ itself (this is a demo
  -- script, not shipped runtime code, so os.execute is acceptable here
  -- purely for pacing the visible counter -- the host module itself has
  -- zero non-stdlib dependencies, which is the actual requirement).
  os.execute("sleep 0.3")
  setCount(i) -- setCount's own setter synchronously runs scheduler.flush()
              -- (see signals/signal.lua), which drives the ordinary
              -- reconciler update path all the way to this host's
              -- commitTextUpdate -- only the terminal repaint itself is
              -- this explicit, additional step.
  host.flush()
end
