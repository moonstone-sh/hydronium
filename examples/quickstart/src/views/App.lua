-- Compiles views/App.luax on demand via hydronium_luax's serve-time
-- loader, cached by mtime -- editing and saving views/App.luax needs no
-- rebuild. Lives in its own requirable module (not a main.lua upvalue):
-- Meteorite's hybrid build mode lifts each inline route handler
-- (extracts its own source text, reloads it standalone per request), so
-- a handler cannot close over a `local App = require(...)` declared
-- above it -- `require("views.App")` from INSIDE a handler body is fine.
local loader = require("hydronium_luax").loader

return loader.load("views/App.luax")
