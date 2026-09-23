-- M2 gate verification (docs/HYDRONIUM_SPA_MODE_PLAN.md): "the emitted
-- chunk load()s in a fresh isolated Lua state." Run with NO LUA_PATH
-- pointing at any real hydronium source tree -- package.path is left at
-- whatever the invoking shell's default is, deliberately NOT exported
-- from this repo's own env, so a pass here proves the chunk is truly
-- self-contained (every module it needs came from inside the chunk
-- itself, not from an accidental real-source fallback on LUA_PATH).
--
-- Usage: luajit verify_chunk_isolated.lua dist/client/runtime-XXXX.lua
local chunk_path = arg[1]
assert(chunk_path, "usage: luajit verify_chunk_isolated.lua <path to chunk>")

local f = assert(io.open(chunk_path, "r"))
local src = f:read("*a")
f:close()

print("chunk size: " .. #src .. " bytes")

local chunk = assert(load(src, "@" .. chunk_path))
chunk() -- installs package.preload[...] for every module the chunk carries
print("chunk loaded and executed: package.preload populated")

local router = assert(require("hydronium_router"))
print("require('hydronium_router') ok, _VERSION=" .. tostring(router._VERSION))

local hash_history = assert(require("hydronium_router.history.hash"))
print("require('hydronium_router.history.hash') ok")

local memory = require("hydronium_router.history.memory")
local hist = memory.create_memory_history({ initial = "/second" })
local r = router.create_router({
  history = hist,
  routes = {
    { id = "home", path = "/", component = function() end },
    { id = "second", path = "/second", component = function() end },
  },
})
assert(r.match().id == "second", "router did not match the seeded /second route")
print("create_router() + real match against the bundled router: ok (matched '" .. r.match().id .. "')")

-- The app module itself is in the chunk too (entries={"app"}).
local app = assert(require("app"))
assert(type(app) == "function", "app module should export a component factory function")
print("require('app') ok: the bundled app entry module is present and callable")

print("\nM2 gate: PASS -- the chunk load()s and requires cleanly in a fresh isolated Lua state")
