--[[
  DISABLED (2026-09-07): this template is intentionally NOT reachable
  through `create.scaffold`/`create.available_templates()` or the CLI's
  `--template` completion list -- see src/create/init.lua's
  `create.scaffold` (it now returns a clear error for `--template spa`
  specifically) and src/main.lua's `c.complete(c.values(...))` list.

  Why: nothing this template promised is real in Hydronium today, and
  making it real is out of scope for hydronium-create (it needs
  foundational work on the hydronium framework side, tracked separately,
  not a scaffolding fix here). Concretely, as of this date:
    - There is no `h.mount(component, selector)` API anywhere in
      src/hydronium -- verified by reading the framework source, not
      assumed. The framework has no notion of mounting a component tree
      into a live browser DOM selector at all yet.
    - There is no client-side bundler or dev-server story for `.luax`
      files served directly to a browser (`<script type="module"
      src="/src/main.luax">` was never going to work -- browsers don't
      compile LUAX, and nothing in this ecosystem transforms it into
      browser-runnable JS ahead of time).
    - There is no `hydronium` CLI binary (the old template's
      `dev`/`build` scripts invoked `hydronium dev`/`hydronium build`,
      neither of which exist). Hydronium core is a `kind = "lib"`
      package, not a `kind = "bin"` executable with subcommands.

  What would need to be true in hydronium before this template could come
  back for real:
    1. A real client bootstrap entry point that can run an actual
       Hydronium component tree in a browser from scratch (not just
       hydrating server-rendered islands, which IS real today -- see the
       `islands` template's JS-island path).
    2. A real bundler/dev-server that can take `.luax` sources and ship
       browser-runnable JS (or a documented, working alternative delivery
       mechanism).
    3. A working `h.mount`/`hydronium.client.mount`-shaped API, verified
       against real framework source the same way every other template in
       this project was fixed.

  Until then, `create.scaffold({template = "spa"})` returns a clear error
  instead of silently generating code that cannot run -- see
  src/create/init.lua.
]]

local spa = {}

function spa.files(opts)
  error("The 'spa' template is disabled -- see the comment at the top of this file for why.", 2)
end

return spa
