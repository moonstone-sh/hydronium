--[[
  TTY detection for hydronium-create's interactive path.

  The interactive wizard ITSELF lives at create/src/create/ui/wizard_app.lua
  -- a real, stateful hydronium_ink component, run for real via
  `hydronium_ink.render(...)` from create/src/main.lua when this module
  reports a real terminal, and exercised in Ink Lab's browser virtual
  terminal via the exact same component (create.stories.lua's
  "install-flow" story). One wizard, not two: this file previously held a
  second, complete, non-Ink implementation (a raw-terminal ANSI form with
  its own key decoding and intro splash) -- removed once the Ink
  component took over as the real CLI's interactive path, so there is
  only ever one place that knows how to walk someone through name ->
  template -> Tailwind -> routing -> summary.
]]

local M = {}

--- True only when BOTH stdin and stdout are a real terminal. Deliberately
--- conservative: piped/redirected input (tests, CI, `... | hydronium-create`)
--- must never trigger the interactive Ink wizard, so a script or CI run
--- always falls through to the ordinary flag-driven path in main.lua.
---
--- MUST use os.execute, not io.popen, for this check. io.popen(cmd, "r")
--- runs the shell with ITS OWN stdout replaced by the pipe io.popen reads
--- from -- so a `[ -t 1 ]` test run that way is asking whether io.popen's
--- internal pipe is a tty, which it never is, regardless of whether THIS
--- process's real stdout is a real terminal. That was a real, previously
--- unverified bug here: the old `shell_line("[ -t 0 ] && [ -t 1 ] && echo
--- 1 || echo 0")` implementation could never return true, in ANY real
--- terminal, because of exactly that -- confirmed via a real pty harness
--- (spawn this CLI under a genuine pseudo-terminal, not a pipe): it
--- printed "--wizard requires an interactive terminal" even with both
--- ends of a real pty attached. The existing unit test only ever asserted
--- `detect_tty() == false` under a piped/non-interactive TEST run, which
--- a permanently-broken implementation also satisfies -- it never
--- exercised the true-case at all. os.execute runs the command with THIS
--- process's real stdin/stdout/stderr, unredirected, so `-t 0`/`-t 1`
--- reflect the real file descriptors.
function M.detect_tty()
  local ok = os.execute("[ -t 0 ] && [ -t 1 ]")
  return ok == true or ok == 0
end

return M
