# Hydronium Ballad integration

This directory contains Hydronium’s Ballad build plugins.

## Server modules (0.2.9)

Requires Moonstone Ballad 0.4.5 or newer.

Production SSR modules can be compiled ahead of request handling with
`require("hydronium_ballad").server_modules(p)` inside a partiture. It emits
plain Lua under `.hydronium/server`, using the existing incremental compile
and directory-sink nodes. Prepend `.hydronium/server/?.lua` and
`.hydronium/server/?/init.lua` to the server's production `package.path`.
Keep the Luax loader in development; request-scoped production Lua VMs should
load the generated Lua rather than compiling templates again on every request.
The optional `root` and `out` settings default to `src` and `.hydronium/server`.
