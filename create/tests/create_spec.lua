package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local create = require("create.init")
local luals = require("create.luals")
local process = require("create.process")
local tailwind = require("create.tailwind")
local router_mode = require("create.router_mode")
local wizard = require("create.wizard")

--- Parses "X.Y.Z" into three integers. Returns nil on anything else.
local function parse_semver(str)
  local major, minor, patch = tostring(str):match("^(%d+)%.(%d+)%.(%d+)$")
  if not major then return nil end
  return tonumber(major), tonumber(minor), tonumber(patch)
end

--- True if `version` (a "X.Y.Z" string) satisfies caret-range `constraint`
--- ("^X.Y.Z"), using the real npm/Cargo-style caret semantics Moonstone
--- itself uses: for a 0.x release, caret only allows the given MINOR
--- (`^0.5.0` means `>=0.5.0 <0.6.0`); for 1.x+, caret allows the given
--- MAJOR (`^1.2.0` means `>=1.2.0 <2.0.0`).
local function satisfies_caret(version, constraint)
  local cmaj, cmin, cpat = parse_semver(constraint:match("^%^?(.+)$"))
  local vmaj, vmin, vpat = parse_semver(version)
  if not cmaj or not vmaj then return false end
  if vmaj ~= cmaj then return false end
  if cmaj == 0 then
    if vmin ~= cmin then return false end
    return vpat >= cpat
  end
  if vmin > cmin then return true end
  if vmin < cmin then return false end
  return vpat >= cpat
end

--- Reads the real, current version of a sibling orbit-member package's own
--- moonstone.toml (e.g. "../ink/moonstone.toml") -- so a test asserting
--- "the create template declares a satisfiable hydronium/ink constraint"
--- tracks whatever hydronium/ink's version actually is, instead of a
--- string literal this file has to remember to update by hand every time
--- that sibling package bumps (which is exactly how this test previously
--- went stale: it asserted a hardcoded "^0.1.1" against a template that
--- had long since moved to "^0.4.0", while the real hydronium/ink had
--- moved to 0.5.0 -- neither side of that comparison was real).
local function sibling_package_version(relative_path)
  local f = assert(io.open(relative_path, "r"), "could not open " .. relative_path)
  local content = f:read("*a")
  f:close()
  local version = content:match('%[package%].-\nversion = "([^"]+)"')
  assert(version, "no [package].version found in " .. relative_path)
  return version
end

local total = 0
local passed = 0

local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  ✓ " .. name)
  else
    print("  ✗ " .. name)
    print("    Error: " .. tostring(err))
  end
end

print("\n--- hydronium-create unit tests ---")

test("available_templates lists all supported templates", function()
  local tmpls = create.available_templates()
  assert(#tmpls == 6, "expected 6 templates, got " .. #tmpls)
  local ids = {}
  for _, t in ipairs(tmpls) do
    ids[t.id] = true
  end
  assert(ids.ssr, "missing ssr template")
  assert(ids.spa, "missing spa template")
  assert(ids.islands, "missing islands template")
  assert(ids.minimal, "missing minimal template")
  assert(ids.ink, "missing ink template")
  assert(ids.love, "missing LÖVE template")
end)

test("scaffold dry-run produces a LÖVE game with a controlled HMR boundary", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-love", template = "love", name = "test-love-app", dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  local files = {}
  for _, file in ipairs(res.created) do files[file.path] = true end
  assert(files["main.lua"], "missing LÖVE entrypoint")
  assert(files["src/App.lua"], "missing game module")
  assert(files["hydronium.sources.lua"], "missing topology declaration")
  assert(files["partiture.lua"], "missing dependency-closed packaging pipeline")
  local generated = require("create.templates.love").files({ name = "test-love-app" })
  local main = generated["main.lua"]
  assert(main:find("love_hmr.from_love", 1, true), "LÖVE scaffold must use the real LÖVE HMR adapter")
  assert(main:find("on_remount", 1, true), "LÖVE scaffold must define a controlled remount boundary")
  assert(generated["moonstone.toml"]:find('name = "luajit"', 1, true), "LÖVE scaffold must select the embedded ABI")
  assert(generated["moonstone.toml"]:find('name = "moonstone/ballad"', 1, true), "LÖVE packaging needs Ballad")
end)

test("add_love layers a bridge onto an existing project without replacing its entrypoint", function()
  local res, err = create.add_love({ directory = "/tmp/test-existing-love", dry_run = true })
  assert(res ~= nil, "add_love returned nil: " .. tostring(err))
  assert(res.additive, "add_love must identify itself as additive")
  local files = {}
  for _, file in ipairs(res.created) do files[file.path] = true end
  assert(files["src/hydronium_love.lua"], "missing additive LÖVE bridge")
  assert(files["HYDRONIUM_LOVE.md"], "missing additive integration instructions")
  assert(files["hydronium.love.partiture.lua"], "missing dependency-closed LÖVE packaging pipeline")
  assert(not files["main.lua"], "add_love must not overwrite the game's entrypoint")
end)

test("add_love uses structured Moonstone operations and synchronizes once", function()
  local target = "/tmp/test-existing-love-command"
  os.execute(string.format('mkdir -p "%s"', target))
  local main = assert(io.open(target .. "/main.lua", "w")); main:write("function love.draw() end\n"); main:close()
  local manifest = assert(io.open(target .. "/moonstone.toml", "w")); manifest:write("manifest_version = 2\n"); manifest:close()
  local calls = {}
  local export = [[{"contract":"moonstone:manifest:v1","manifest":{"runtime":{"name":"luajit","version":"2.1.0","abi":"5.1"},"dependencies":[],"scripts":[]}}]]
  local res, err = create.add_love({
    directory = target,
    run_process = function(spec)
      calls[#calls + 1] = spec
      if spec.args[1] == "manifest" and spec.args[2] == "export" then
        return { exit_code = 0, stdout = export, stderr = "" }
      end
      return { exit_code = 0, stdout = "", stderr = "" }
    end,
    write_project = function(_, files)
      local created = {}
      for path, content in pairs(files) do created[#created + 1] = { path = path, size = #content } end
      return { created = created }
    end,
  })
  assert(res ~= nil, "injected add_love should succeed: " .. tostring(err))
  assert(res.synced, "successful add-on must finish moon sync")
  local flattened = {}
  for _, call in ipairs(calls) do flattened[#flattened + 1] = table.concat(call.args, " ") end
  local commands = table.concat(flattened, "\n")
  assert(commands:find("add --role runtime --no-sync hydronium/core", 1, true), commands)
  assert(commands:find("add --tool --no-sync moonstone/ballad", 1, true), commands)
  assert(commands:find("manifest script set love-dev --command love .", 1, true), commands)
  assert(flattened[#flattened] == "sync", "sync must be the final operation")
  os.remove(target .. "/main.lua")
  os.remove(target .. "/moonstone.toml")
  os.execute(string.format('rmdir "%s" 2>/dev/null', target))
end)

test("add_love refuses an incompatible existing runtime before mutation", function()
  local target = "/tmp/test-existing-love-wrong-abi"
  os.execute(string.format('mkdir -p "%s"', target))
  local main = assert(io.open(target .. "/main.lua", "w")); main:write("function love.draw() end\n"); main:close()
  local original = "manifest_version = 2\n# keep me\n"
  local manifest = assert(io.open(target .. "/moonstone.toml", "w")); manifest:write(original); manifest:close()
  local calls = 0
  local res, err = create.add_love({
    directory = target,
    run_process = function(spec)
      calls = calls + 1
      assert(spec.args[1] == "manifest" and spec.args[2] == "export", "runtime refusal must not mutate")
      return { exit_code = 0, stdout = [[{"manifest":{"runtime":{"name":"lua","version":"5.4","abi":"5.4"}}}]], stderr = "" }
    end,
  })
  assert(res == nil and err:find("moon interpreter set luajit@2.1", 1, true), tostring(err))
  assert(calls == 1, "only the read-only manifest export should run")
  local restored = assert(io.open(target .. "/moonstone.toml", "r")); assert(restored:read("*a") == original); restored:close()
  os.remove(target .. "/main.lua"); os.remove(target .. "/moonstone.toml")
  os.execute(string.format('rmdir "%s" 2>/dev/null', target))
end)

test("add_love initializes non-Moonstone games and rolls back pre-sync failures", function()
  local target = "/tmp/test-existing-love-rollback"
  os.execute(string.format('mkdir -p "%s"', target))
  local main = assert(io.open(target .. "/main.lua", "w")); main:write("function love.draw() end\n"); main:close()
  os.remove(target .. "/moonstone.toml")
  local calls = {}
  local res, err = create.add_love({
    directory = target,
    run_process = function(spec)
      calls[#calls + 1] = table.concat(spec.args, " ")
      if spec.args[1] == "manifest" and spec.args[2] == "export" then
        return { exit_code = 0, stdout = [[{"manifest":{"runtime":{"name":"love","version":"11.5","abi":"5.1"},"dependencies":[],"scripts":[]}}]], stderr = "" }
      end
      return { exit_code = 0, stdout = "", stderr = "" }
    end,
    write_project = function() return nil, "simulated write failure" end,
  })
  assert(res == nil and err == "simulated write failure", tostring(err))
  assert(calls[1]:find("init .", 1, true), "a non-Moonstone game must be initialized first")
  assert(calls[1]:find("--interpreter luajit@2.1", 1, true), calls[1])
  assert(calls[1]:find("--empty", 1, true), "initialization must not create or replace game files")
  assert(io.open(target .. "/moonstone.toml", "r") == nil, "pre-sync failure must remove a newly-created manifest")
  os.remove(target .. "/main.lua")
  os.execute(string.format('rmdir "%s" 2>/dev/null', target))
end)

test("process builder quotes POSIX paths and rejects unsafe Windows cmd input", function()
  local command = process.build_command({ tool = "moon", cwd = "/tmp/a game's", args = { "add", "hydronium/core" } }, "posix")
  assert(command:find("'/tmp/a game'\\''s'", 1, true), command)
  local ok = pcall(process.build_command, { tool = "moon", cwd = "C:/game & tools", args = { "sync" } }, "windows")
  assert(not ok, "Windows cmd metacharacters must fail closed")
  local windows = process.build_command({ tool = "moon", cwd = "C:/Games/My Game", args = { "sync" } }, "windows")
  assert(windows:find('pushd "C:/Games/My Game"', 1, true), windows)
end)

test("scaffold dry-run produces a portable Ink terminal project", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-ink",
    template = "ink",
    name = "test-ink-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  assert(res.next_script == "run", "ink should direct users to the run script")

  local file_map = {}
  for _, file in ipairs(res.created) do file_map[file.path] = true end
  assert(file_map["moonstone.toml"], "missing moonstone.toml")
  assert(file_map[".gitignore"], "missing .gitignore")
  assert(file_map["run.lua"], "missing run.lua")
  assert(file_map["src/app.luax"], "missing src/app.luax")
  assert(file_map["src/App.stories.luax"], "missing starter Lab story")
  assert(file_map["hydronium.sources.lua"], "missing explicit source topology")
  assert(file_map["README.md"], "missing README.md")
  assert(file_map[".luarc.json"], "missing .luarc.json")
  local run_lua = require("create.templates.ink").files({ name = "test-ink-app" })["run.lua"]
  assert(run_lua and run_lua:find('require%("hydronium.core.hmr"%)'), "Ink run.lua must use shared core HMR")
  assert(run_lua:find('require%("hydronium.core.hmr_host"%)'), "Ink run.lua must commit through the shared host boundary")
  assert(run_lua:find("pcall(updates.flush", 1, true), "Ink run.lua must flush queued updates between event-loop turns")
  assert(run_lua:find("onTick", 1, true), "Ink run.lua must poll refreshes inside the renderer loop")
  assert(run_lua:find("hydronium.sources.lua", 1, true), "Ink run.lua must consume the project source topology")
  assert(run_lua:find("source_inventory.load", 1, true), "Ink must prefer a generated source inventory when available")
  assert(run_lua:find("source_topology.resolve", 1, true), "Ink run.lua must resolve source records rather than infer conventions")
  assert(run_lua:find("updates:queue_batch", 1, true), "Ink run.lua must deliver multi-file changes as one batch")
  local manifest = require("create.templates.ink").files({ name = "test-ink-app" })["moonstone.toml"]
  assert(manifest:find('lab = "moon exec --dev -- hydronium-lab dev"', 1, true), "Ink must expose a standalone Lab script")
  assert(manifest:find('name = "hydronium/lab-cli"', 1, true), "Ink Lab must include the standalone Lab CLI tool")
  assert(manifest:find('name = "hydronium/ink-lab"', 1, true), "Ink Lab must include its renderer adapter")
  assert(manifest:find('name = "hydronium/lab"\nconstraint = "^0.2.0"\nrole = "dev"', 1, true), "Ink Lab renderer must stay dev-only")
  local story = require("create.templates.ink").files({ name = "test-ink-app" })["src/App.stories.luax"]
  assert(story:find("lab.collection", 1, true), "Ink must generate a convention Lab story")
end)

test("Ink rejects non-LuaJIT interpreters before writing", function()
  local target = "/tmp/test-hydronium-ink-wrong-runtime"
  os.execute(string.format('rm -rf "%s"', target))
  local res, err = create.scaffold({
    directory = target,
    template = "ink",
    interpreter = "lua@5.4",
  })
  assert(res == nil, "expected Ink scaffold to reject PUC Lua")
  assert(err:find("luajit@2.1", 1, true), "error should name the supported interpreter")
  local exists = io.open(target .. "/moonstone.toml", "r")
  assert(exists == nil, "runtime rejection must happen before files are written")
  if exists then exists:close() end
end)

test("scaffold dry-run produces a real client-only static SPA (router=hydronium, the default)", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-spa-hydronium",
    template = "spa",
    name = "test-spa-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  assert(res.router == nil or res.router == "hydronium", "default spa router should read as hydronium (or unset)")
  assert(res.next_script == "build", "the static spa variant has no dev server -- next step is build")
  local file_map = {}
  for _, f in ipairs(res.created) do file_map[f.path] = true end
  assert(file_map["app.lua"], "missing app.lua")
  assert(file_map["partiture.lua"], "missing partiture.lua")
  assert(file_map["app.css"], "missing app.css")
  assert(not file_map["build.zig"], "the static (hydronium-router) spa variant must have no Zig/Meteorite build at all")
  assert(not file_map["src/main.lua"], "the static (hydronium-router) spa variant must have no server entrypoint")

  local generated = require("create.templates.spa").files({ name = "test-spa-app", router = "hydronium" })
  assert(generated["app.lua"]:find("hydronium_router.history.hash", 1, true), "must use hash-based client routing")
  assert(generated["app.lua"]:find("R.createSite", 1, true), "must use a real hydronium_router site manifest")
  assert(generated["partiture.lua"]:find("hb.plugins.client", 1, true), "must use the real Ballad client bundler")
  assert(generated["partiture.lua"]:find("router_src", 1, true), "hydronium router variant must bundle the router source")
  assert(generated["partiture.lua"]:find("hydrate = false", 1, true), "a static SPA has no SSR markup to hydrate")
  assert(not generated["moonstone.toml"]:find("path:", 1, true), "must not emit path constraints")
end)

test("scaffold dry-run produces a real Meteorite-served single-screen SPA (router=meteorite)", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-spa-meteorite",
    template = "spa",
    name = "test-spa-meteorite",
    router = "meteorite",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  assert(res.router == "meteorite")
  assert(res.next_script == "dev", "the meteorite spa variant has a real dev server")
  local file_map = {}
  for _, f in ipairs(res.created) do file_map[f.path] = true end
  assert(file_map["build.zig"], "the meteorite spa variant must have a real Zig build")
  assert(file_map["src/main.lua"], "the meteorite spa variant must have a Meteorite server entrypoint")

  local generated = require("create.templates.spa").files({ name = "test-spa-meteorite", router = "meteorite" })
  assert(not generated["app.lua"]:find('require("hydronium_router")', 1, true), "meteorite variant must not bundle the client router")
  assert(not generated["partiture.lua"]:find("router_src", 1, true), "meteorite variant must not resolve router sources")
  assert(generated["src/main.lua"]:find("meteorite.site", 1, true), "must serve the Ballad-built dist/ via Meteorite")
  assert(not generated["moonstone.toml"]:find('name = "hydronium/router"', 1, true), "meteorite variant has no router dependency")
end)

test("scaffold dry-run produces expected files for ssr template", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-app",
    template = "ssr",
    name = "test-ssr-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  assert(res.project_name == "test-ssr-app")
  assert(res.template == "ssr")

  local file_map = {}
  for _, f in ipairs(res.created) do
    file_map[f.path] = true
  end
  assert(file_map["moonstone.toml"], "missing moonstone.toml")
  assert(file_map["src/main.lua"], "missing src/main.lua")
  assert(file_map["src/views/Document.lua"], "missing src/views/Document.lua")
  assert(file_map["src/views/Document.luax"], "missing src/views/Document.luax")
  assert(file_map["src/views/App.luax"], "missing src/views/App.luax")
  assert(file_map["src/views/Counter.luax"], "missing src/views/Counter.luax")
  assert(file_map["hydronium.sources.lua"], "missing source topology manifest")
  assert(file_map["public/style.css"], "missing public/style.css")
  assert(file_map["build.zig"], "missing build.zig")
  assert(not file_map["src/hydronium"], "generated projects must resolve Hydronium through dependencies, not a source symlink")

  local generated = require("create.templates.ssr").files({ name = "test-ssr-app" })
  local manifest = generated["client_manifest.json"]
  assert(manifest:find('"hydronium_router.history.state"', 1, true),
    "SSR client manifest must include browser history state decoding")
  assert(manifest:find('"hydronium.core.hmr_host"', 1, true),
    "SSR client manifest must include the browser HMR host coordinator")
  assert(manifest:find('"hydronium.core.module_graph"', 1, true),
    "SSR client manifest must include the runtime module graph")
  assert(manifest:find('"hydronium.core.love_hmr"', 1, true),
    "SSR client manifest must include the core barrel's LÖVE HMR dependency")
  assert(manifest:find('"hydronium.core.source_topology"', 1, true),
    "SSR client manifest must include the core barrel's source topology dependency")
  assert(manifest:find('"hydronium_router.topology"', 1, true),
    "SSR client manifest must include the router's topology dependency")
  assert(not generated["moonstone.toml"]:find("path:../", 1, true), "SSR dependencies must install without sibling checkouts")
  assert(generated["build.zig"]:find("meteorite/meteorite/zig/build_api.zig", 1, true),
    "SSR build must use the installed Meteorite package layout")
  assert(generated["src/main.lua"]:find("libexec/router/hydronium_router/client/history.js", 1, true),
    "SSR must serve the packaged router client assets")
  assert(generated["src/main.lua"]:find("libexec/dom/hydronium_dom/client/vendor", 1, true),
    "SSR must serve DOM client assets from Moonstone's package-leaf libexec layout")
  assert(not generated["src/main.lua"]:find("dev_registry", 1, true),
    "SSR hybrid handlers must not capture an outer registry helper")
  assert(generated["src/main.lua"]:find("hydronium_dom.dev.source_registry", 1, true),
    "SSR must resolve browser modules through the source registry")
  assert(generated["src/main.lua"]:find("load_inventory", 1, true),
    "SSR must prefer Ballad's generated source inventory when it exists")
  assert(generated["src/main.lua"]:find("registry:module(id)", 1, true),
    "SSR must whitelist declared module IDs")
  assert(generated["src/main.lua"]:find("passive = { \"src/views/App.luax\"", 1, true),
    "SSR must classify client UI source as passive Meteorite input")
  assert(not generated["src/main.lua"]:find('id:gsub("%%.", "/")', 1, true),
    "SSR must not reconstruct filesystem paths from request IDs")
end)

test("scaffold dry-run produces expected files for islands template", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-islands",
    template = "islands",
    name = "test-islands-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  local file_map = {}
  for _, f in ipairs(res.created) do
    file_map[f.path] = true
  end
  assert(file_map["views/Document.luax"], "missing views/Document.luax")
  assert(file_map["src/views/Document.lua"], "missing src/views/Document.lua")
  assert(file_map["public/js/bootstrap/bootstrap.js"], "missing public/js/bootstrap/bootstrap.js")
  assert(file_map["public/js/bootstrap/boundary_registry.js"], "missing public/js/bootstrap/boundary_registry.js")
  assert(file_map["public/js/bootstrap/priority.js"], "missing public/js/bootstrap/priority.js")
  assert(file_map["public/js/island/counter.js"], "missing public/js/island/counter.js")
  local generated = require("create.templates.islands").files({ name = "test-islands-app" })
  assert(not generated["moonstone.toml"]:find("path:../", 1, true), "Islands dependencies must install without sibling checkouts")
  assert(generated["build.zig"]:find("meteorite/meteorite/zig/build_api.zig", 1, true),
    "Islands build must use the installed Meteorite package layout")
end)

-- The `dev` script is the one line in a generated project a user runs on
-- day one, and it has two independent ways to be silently wrong: naming a
-- binary the project does not depend on, and omitting the mandatory `--`
-- separator `moon exec` requires between its own flags and the child command.
for _, template_id in ipairs({ "ssr", "islands" }) do
  test(template_id .. " dev script runs `hydronium dev` with this project's real meteorite flags", function()
    local generated = require("create.templates." .. template_id).files({ name = "test-" .. template_id })
    local manifest = generated["moonstone.toml"]

    local dev = manifest:match("\ndev = \"([^\"]+)\"")
    assert(dev, "[" .. template_id .. "] no dev script in the generated moonstone.toml")

    assert(dev:find("hydronium dev", 1, true),
      "[" .. template_id .. "] dev script must run `hydronium dev`, got: " .. dev)
    assert(not dev:find("meteorite dev", 1, true),
      "[" .. template_id .. "] dev script must not invoke `meteorite dev` directly any more, got: " .. dev)

    -- The flags meteorite dev has no defaults for. It errors without
    -- --mode/--backend, so a generated project that omits them is broken
    -- on first run.
    local args = dev:match("%-%-meteorite%-args='([^']+)'")
    assert(args, "[" .. template_id .. "] meteorite flags must travel in a single quoted --meteorite-args value, got: " .. dev)
    assert(args:find("--mode hybrid_dev", 1, true), "[" .. template_id .. "] missing --mode: " .. args)
    assert(args:find("--backend fast_http", 1, true), "[" .. template_id .. "] missing --backend: " .. args)
    assert(args:find("--lua-root .moonstone/env/libexec/luajit", 1, true),
      "[" .. template_id .. "] missing --lua-root: " .. args)

    assert(dev:find("moon exec %-%-dev %-%- hydronium dev", 1, false),
      "[" .. template_id .. "] dev script must separate moon's own flags from the child command: " .. dev)

    -- ...and the binary that script calls has to actually be in the
    -- project's environment, which means a declared dependency.
    assert(manifest:find('name = "hydronium/cli"'),
      "[" .. template_id .. "] dev script calls `hydronium` but nothing declares hydronium/cli")
    assert(manifest:match('name = "hydronium/cli"%s*\nconstraint = "[^"]+"%s*\nrole = "tool"'),
      "[" .. template_id .. "] hydronium-cli must be a tool dependency (it is a dev-time binary, not a runtime library)")
    assert(not manifest:find("path:", 1, true),
      "[" .. template_id .. "] dependencies must install without a sibling checkout")

    -- `build` is untouched: this CLI wraps the dev server only.
    local build = manifest:match("\nbuild = \"([^\"]+)\"")
    assert(build and build:find("meteorite build", 1, true),
      "[" .. template_id .. "] build script must still call meteorite build directly, got: " .. tostring(build))
    assert(build and build:find("moon exec --dev -- meteorite build", 1, true),
      "[" .. template_id .. "] build script must separate Meteorite flags from Moonstone options: " .. tostring(build))

    -- The generated README has to tell the user what `moon run dev` now
    -- shows them, including how to reach the fullscreen view.
    local readme = generated["README.md"]
    assert(readme:find("hydronium dev", 1, true), "[" .. template_id .. "] README does not mention hydronium dev")
    assert(readme:find("fullscreen", 1, true), "[" .. template_id .. "] README does not document the fullscreen view")

    assert(generated[".gitignore"]:find(".hydronium/", 1, true),
      "[" .. template_id .. "] .hydronium/ (the CLI's own dev log) must be gitignored")
  end)
end

test("minimal template has no dev server to wrap", function()
  -- Deliberate: `minimal` is a `kind = "script"` project with no
  -- Meteorite, no server and a `run` script -- there is no dev server for
  -- `hydronium dev` to supervise, so it must NOT gain the CLI dependency.
  local generated = require("create.templates.minimal").files({ name = "test-minimal-app" })
  local manifest = generated["moonstone.toml"]
  assert(not manifest:find("hydronium%-cli"), "minimal must not depend on the dev CLI")
  assert(not manifest:find("\ndev = ", 1, true), "minimal has no dev script")
  assert(manifest:find('run = "lua src/main.lua"', 1, true), "minimal still runs its script directly")
end)

test("minimal template uses registry dependencies", function()
  local generated = require("create.templates.minimal").files({ name = "test-minimal-app" })
  assert(not generated["moonstone.toml"]:find("path:../", 1, true), "Minimal dependencies must install without sibling checkouts")
end)

test("scaffold rejects invalid template name", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-invalid",
    template = "non-existent-template",
    dry_run = true,
  })
  assert(res == nil, "expected error for unknown template")
  assert(err:find("Unknown template"), "expected Unknown template error message")
end)

test("luals.configure uses alter to update .luarc.json with Hydronium LuaX plugin", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  local res, err = luals.configure(tmp_dir, {
    interpreter = "lua@5.4",
  })
  assert(res ~= nil, "luals.configure failed: " .. tostring(err))
  assert(res.changed == true, "expected changed to be true")

  local f = io.open(tmp_dir .. "/.luarc.json", "r")
  assert(f ~= nil, "could not open generated .luarc.json")
  local content = f:read("*a")
  f:close()

  assert(content:find("hydronium_luax/luals/init.lua"), "missing hydronium_luax plugin in .luarc.json")
  assert(content:find("%.moonstone/env/share/lua/5.4"), "missing workspace library in .luarc.json")
  assert(content:find("%.moonstone/env/libexec/core/types"), "missing Hydronium core form types library")
  assert(content:find("libexec/luax/types", 1, true), "missing packaged LUAX types in .luarc.json")
  assert(content:find("libexec/dom/types", 1, true), "missing packaged DOM types in .luarc.json")
  assert(content:find("%*%.luax"), "missing *.luax association in .luarc.json")

  -- Idempotency check: running again should succeed without redundant duplicates
  local res2, err2 = luals.configure(tmp_dir, {
    interpreter = "lua@5.4",
  })
  assert(res2 ~= nil, "idempotent luals.configure failed: " .. tostring(err2))

  os.execute(string.format('rm -rf "%s"', tmp_dir))
end)

-- Regression guard for a real, verified editor behaviour: Meteorite
-- generates per-route LuaCATS classes into `.meteorite/aids/lua` on every
-- graph/build, and `MeteoriteApp`'s path-literal overloads really do give
-- `c` a specific type inside `app:get(path, function(c) ... end)` -- but
-- ONLY if those files are on LuaLS's path. They were not, in every real
-- scaffolded project checked. Measured with a real
-- textDocument/completion request against lua-language-server 3.18.2-dev,
-- at `c.params.` inside `app:get("/hydronium-src/:path*", function(c)`:
-- 100 junk word-completions before, exactly one (`path`) after.
test("luals.configure puts Meteorite's generated LuaCATS aids on the LuaLS path", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  local res, err = luals.configure(tmp_dir, { interpreter = "luajit@2.1", meteorite = true })
  assert(res ~= nil, "luals.configure failed: " .. tostring(err))

  local f = assert(io.open(tmp_dir .. "/.luarc.json", "r"))
  local content = f:read("*a")
  f:close()

  -- workspace.library makes LuaLS load the generated classes at all...
  assert(content:find("%.meteorite/aids/lua\""), "missing .meteorite/aids/lua workspace library entry")
  -- ...and runtime.path is what lets `require("meteorite")` resolve to the
  -- generated stub that declares those typed overloads.
  assert(content:find("%.meteorite/aids/lua/%?%.lua"), "missing .meteorite/aids/lua/?.lua runtime path entry")
  assert(content:find("%.meteorite/aids/lua/%?/init%.lua"), "missing .meteorite/aids/lua/?/init.lua runtime path entry")
  -- Adding the Meteorite searchers must NOT clobber the LUAX one. Two
  -- separate `runtime:at("path")` cursors silently did exactly that,
  -- because the second cursor does not observe the first's pending set().
  assert(content:find("%?%.luax"), "meteorite wiring clobbered the ?.luax searcher")

  os.execute(string.format('rm -rf "%s"', tmp_dir))
end)

test("luals.configure leaves non-Meteorite templates free of Meteorite aids", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  -- The `minimal` template's tooling: no luax, no meteorite.
  local res, err = luals.configure(tmp_dir, { interpreter = "lua@5.4", luax = false, meteorite = false })
  assert(res ~= nil, "luals.configure failed: " .. tostring(err))

  local f = assert(io.open(tmp_dir .. "/.luarc.json", "r"))
  local content = f:read("*a")
  f:close()

  assert(not content:find("%.meteorite/aids"), "non-Meteorite template should not reference Meteorite aids")

  os.execute(string.format('rm -rf "%s"', tmp_dir))
end)

test("luals.configure composes with commented user config idempotently", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  local config = assert(io.open(tmp_dir .. "/.luarc.json", "w"))
  config:write([[// keep this project note
{
  "runtime": {
    "plugin": "existing-plugin.lua",
    "path": ["?.lua", "custom/?.lua"]
  },
  "workspace": { "library": ["existing-types"] }
}
]])
  config:close()

  local first, first_err = luals.configure(tmp_dir, {
    interpreter = "luajit@2.1",
    luax = true,
    dom = true,
    bare_dom = true,
  })
  assert(first ~= nil, "first configure failed: " .. tostring(first_err))
  assert(first.changed == true, "first configure should mutate the user config")

  local second, second_err = luals.configure(tmp_dir, {
    interpreter = "luajit@2.1",
    luax = true,
    dom = true,
    bare_dom = true,
  })
  assert(second ~= nil, "second configure failed: " .. tostring(second_err))
  assert(second.changed == false, "second configure must be idempotent")

  local configured = assert(io.open(tmp_dir .. "/.luarc.json", "r"))
  local content = configured:read("*a")
  configured:close()
  assert(content:find("// keep this project note", 1, true), "Alter must preserve JSONC comments")
  assert(content:find("existing%-plugin%.lua"), "Alter must preserve an existing plugin")
  assert(content:find("custom/%?%.lua"), "Alter must preserve custom runtime search paths")
  assert(content:find("%?%.luax"), "Alter must compose the LUAX runtime search path")
  assert(content:find("hydronium_luax/luals/init.lua", 1, true), "Hydronium plugin was not composed")
  assert(content:find("existing%-types"), "Alter must preserve existing workspace libraries")
  assert(content:find("ambient%-types"), "bare DOM types were not composed")

  os.execute(string.format('rm -rf "%s"', tmp_dir))
end)

test("CLI declarations and completion run on Clingy 0.6", function()
  local handle = assert(io.popen([[lua ./src/main.lua --__clingy-complete bash hydronium-create --template '' --cword=3]]))
  local output = handle:read("*a")
  local closed = handle:close()
  assert(closed, "hydronium-create completion process failed")
  assert(output:find("V\t2", 1, true), "missing Clingy completion protocol header")
  assert(output:find("C\tssr", 1, true), "missing ssr completion")
  assert(output:find("C\tislands", 1, true), "missing islands completion")
  assert(output:find("C\tink", 1, true), "missing ink completion")
  assert(not output:find("C\tminimal", 1, true), "minimal must be exposed as --minimal, not a template value")
end)

test("CLI exposes minimal as an exclusive flag", function()
  local minimal = assert(io.popen([[lua ./src/main.lua --minimal --dry-run 2>&1]]))
  local minimal_output = minimal:read("*a")
  assert(minimal:close(), "--minimal dry-run failed")
  assert(minimal_output:find("src/main.lua", 1, true), "--minimal did not select the minimal scaffold")
  assert(minimal_output:find("moon run run", 1, true), "--minimal printed the wrong next step")

  local mixed = assert(io.popen([[lua ./src/main.lua --minimal --template ink --dry-run 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local mixed_output = mixed:read("*a")
  mixed:close()
  assert(mixed_output:find("__EXIT__1", 1, true), "--minimal with --template should fail")
  assert(mixed_output:find("cannot be combined", 1, true), "mixed selector error is unclear")

  local legacy = assert(io.popen([[lua ./src/main.lua --template minimal --dry-run 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local legacy_output = legacy:read("*a")
  legacy:close()
  assert(legacy_output:find("__EXIT__1", 1, true), "--template minimal should be rejected")
  assert(legacy_output:find("selected with %-%-minimal"), "legacy selector error should direct users to --minimal")
end)

test("--install and --git mirror the wizard's own toggles, running the real (non-dry-run) task runner", function()
  local target = "/tmp/test-cli-install-git"
  os.execute(string.format('rm -rf "%s"', target))
  local handle = assert(io.popen(string.format(
    [[lua ./src/main.lua "%s" --minimal --install --git 2>&1; printf '\n__EXIT__%%s\n' "$?"]], target)))
  local output = handle:read("*a")
  handle:close()
  assert(output:find("__EXIT__0", 1, true), output)
  assert(output:find("moon sync: done", 1, true), output)
  assert(output:find("git init: done", 1, true), output)
  local git_dir = io.open(target .. "/.git/HEAD", "r")
  assert(git_dir ~= nil, "--git must really run `git init`, not just print a next step")
  if git_dir then git_dir:close() end
  local env_dir = io.open(target .. "/.moonstone/env", "r")
  -- .moonstone/env is a directory, not a readable file, but its mere
  -- existence proves `moon sync` really ran -- assert via `ls` instead.
  local ls = assert(io.popen(string.format('ls -d "%s/.moonstone/env" 2>/dev/null', target)))
  local ls_out = ls:read("*a")
  ls:close()
  assert(ls_out:find(".moonstone/env", 1, true), "--install must really run `moon sync`, not just print a next step")
  os.execute(string.format('rm -rf "%s"', target))
end)

test("--install and --git are dry-run-safe and refuse contradictory pairs", function()
  local handle = assert(io.popen([[lua ./src/main.lua /tmp/test-cli-install-dry --minimal --install --git --dry-run 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local output = handle:read("*a")
  handle:close()
  assert(output:find("__EXIT__0", 1, true), output)
  assert(not output:find("moon sync: done", 1, true), "dry-run must never actually invoke moon sync")
  assert(not output:find("git init: done", 1, true), "dry-run must never actually invoke git init")
  assert(io.open("/tmp/test-cli-install-dry/moonstone.toml", "r") == nil, "dry-run must not write any files")

  local conflict = assert(io.popen([[lua ./src/main.lua /tmp/x --minimal --install --no-install --dry-run 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local conflict_output = conflict:read("*a")
  conflict:close()
  assert(conflict_output:find("__EXIT__1", 1, true), conflict_output)
  assert(conflict_output:find("cannot be combined", 1, true), conflict_output)
end)

--------------------------------------------------------------------------------
-- Wizard, --tailwind, and --router: every wizard choice is also a flag, and
-- the scaffolding logic stays a pure function of the collected options (see
-- create/init.lua and create/wizard.lua's own header comments for why).
--------------------------------------------------------------------------------

test("wizard.detect_tty never blocks a non-interactive test run", function()
  -- This test process's stdin/stdout are pipes (the test runner itself was
  -- launched via `moon run test` / `lua ./tests/create_spec.lua`, not a
  -- terminal), so this must be false here -- if it were ever true by
  -- accident, main.lua would try to mount the real Ink wizard and hang
  -- this very test.
  assert(wizard.detect_tty() == false, "detect_tty must be false under a piped test runner")
end)

-- The interactive wizard itself (name -> template -> Tailwind -> routing
-- -> summary -> result) is create.ui.wizard_app -- a real Ink component,
-- exercised for real via a headless hydronium_ink.session by the
-- "create.stories.lua loads and every non-interactive story renders" and
-- "install-flow story is a real, stateful, keyboard-driven walk..." tests
-- further down in this file. Nothing wizard-shaped is tested here beyond
-- detect_tty: there is only one implementation to cover.

test("CLI --wizard fails closed (never hangs) on a non-interactive stdin", function()
  local handle = assert(io.popen([[lua ./src/main.lua --wizard --dry-run < /dev/null 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local output = handle:read("*a")
  handle:close()
  assert(output:find("__EXIT__1", 1, true), "explicit --wizard on a non-tty must fail, not hang or silently proceed")
  assert(output:find("interactive terminal", 1, true), output)
end)

test("CLI ambient auto-wizard does not trigger for a non-interactive invocation", function()
  -- No --template/--minimal/--name/--directory/--yes given, but stdin/stdout
  -- are pipes here too (io.popen), so this must fall through to the
  -- ordinary flag-driven default (ssr) instead of hanging on a prompt.
  local handle = assert(io.popen([[lua ./src/main.lua --dry-run 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local output = handle:read("*a")
  handle:close()
  assert(output:find("__EXIT__0", 1, true), output)
  assert(output:find("template 'ssr'", 1, true), output)
end)

test("tailwind.apply wires Vite + Tailwind v4 into the ssr template", function()
  local files = require("create.templates.ssr").files({ name = "test-ssr-tailwind" })
  files = tailwind.apply(files, { template = "ssr", name = "test-ssr-tailwind" })
  assert(files["package.json"]:find('"@tailwindcss/vite"', 1, true), "missing @tailwindcss/vite devDependency")
  assert(files["package.json"]:find('"tailwindcss"', 1, true), "missing tailwindcss devDependency")
  assert(files["vite.config.js"]:find('tailwindcss()', 1, true), "vite.config.js must register the Tailwind plugin")
  assert(files["src/styles.css"]:find('@import "tailwindcss";', 1, true), "missing Tailwind v4 CSS-first import")
  assert(files["src/styles.css"]:find('@source "./views/**/*.luax";', 1, true),
    "missing explicit @source for .luax views -- Tailwind cannot detect that extension on its own")
  assert(files["src/views/Document.luax"]:find('/public/dist/styles.css', 1, true),
    "Document must link the compiled Tailwind stylesheet")
  assert(files[".gitignore"]:find("node_modules/", 1, true), "must gitignore node_modules")
end)

test("tailwind.apply wires Vite + Tailwind v4 into the islands template", function()
  local files = require("create.templates.islands").files({ name = "test-islands-tailwind" })
  files = tailwind.apply(files, { template = "islands", name = "test-islands-tailwind" })
  assert(files["src/styles.css"]:find('@source "../views/**/*.luax";', 1, true),
    "islands' .luax views live one level above src/, unlike ssr's")
  assert(files["views/Document.luax"]:find('/public/dist/styles.css', 1, true),
    "Document must link the compiled Tailwind stylesheet")
end)

test("tailwind.apply refuses templates it has no wiring for", function()
  local files = require("create.templates.minimal").files({ name = "test-minimal" })
  local ok, err = pcall(tailwind.apply, files, { template = "minimal", name = "test-minimal" })
  assert(not ok, "tailwind.apply must refuse an unsupported template")
  assert(tostring(err):find("unsupported template", 1, true), tostring(err))
end)

test("router_mode.apply_islands replaces the single hand-written route with a Hydronium Router site", function()
  local files = require("create.templates.islands").files({ name = "test-islands-router" })
  files = router_mode.apply_islands(files, { name = "test-islands-router" })

  assert(files["moonstone.toml"]:find('name = "hydronium/router"', 1, true), "must add the hydronium/router dependency")
  assert(files["views/Site.lua"], "missing views/Site.lua route manifest")
  assert(files["views/Home.luax"], "missing views/Home.luax (split out of Document.luax)")
  assert(files["views/About.luax"], "missing views/About.luax second page")
  assert(files["src/views/Home.lua"] and files["src/views/About.lua"], "missing loader wrappers for the new screens")
  assert(files["src/app/page_handler.lua"], "missing router-driven page handler")

  assert(files["src/main.lua"]:find("hydronium_router.meteorite", 1, true), "src/main.lua must use the router adapter")
  assert(files["src/main.lua"]:find("router_adapter.mount", 1, true), "src/main.lua must mount the site")
  assert(files["src/main.lua"]:find("router_adapter.validate_final", 1, true), "src/main.lua must validate the final route table")
  assert(not files["src/main.lua"]:find('app:get%("/1"', 1, false), "sanity: no leftover placeholder route")

  assert(files["views/Site.lua"]:find('screen = "views.Home"', 1, true), "site must declare the home screen")
  assert(files["views/Site.lua"]:find('screen = "views.About"', 1, true), "site must declare the about screen")
end)

test("create.scaffold(--tailwind) produces the expected extra files for ssr and islands, dry-run", function()
  for _, template_id in ipairs({ "ssr", "islands" }) do
    local res, err = create.scaffold({
      directory = "/tmp/test-hydronium-tailwind-" .. template_id,
      template = template_id,
      name = "test-" .. template_id .. "-tw",
      tailwind = true,
      dry_run = true,
    })
    assert(res ~= nil, "[" .. template_id .. "] scaffold with --tailwind failed: " .. tostring(err))
    local file_map = {}
    for _, f in ipairs(res.created) do file_map[f.path] = true end
    assert(file_map["package.json"], "[" .. template_id .. "] missing package.json")
    assert(file_map["vite.config.js"], "[" .. template_id .. "] missing vite.config.js")
    assert(file_map["src/styles.css"], "[" .. template_id .. "] missing src/styles.css")
    assert(res.tailwind == true, "[" .. template_id .. "] result must report tailwind = true")
    assert(res.package_manager ~= nil, "[" .. template_id .. "] must resolve a package manager when --tailwind is set")
  end
end)

test("create.scaffold(--tailwind) on spa uses the postbuild-patch strategy, both router variants", function()
  for _, router in ipairs({ "hydronium", "meteorite" }) do
    local res, err = create.scaffold({
      directory = "/tmp/test-hydronium-tailwind-spa-" .. router,
      template = "spa",
      name = "test-spa-tw-" .. router,
      router = router,
      tailwind = true,
      dry_run = true,
    })
    assert(res ~= nil, "[spa/" .. router .. "] scaffold with --tailwind failed: " .. tostring(err))
    local file_map = {}
    for _, f in ipairs(res.created) do file_map[f.path] = true end
    assert(file_map["package.json"], "[spa/" .. router .. "] missing package.json")
    assert(file_map["vite.config.js"], "[spa/" .. router .. "] missing vite.config.js")
    assert(file_map["src/styles.css"], "[spa/" .. router .. "] missing src/styles.css")
    assert(file_map["scripts/inject-tailwind-link.mjs"], "[spa/" .. router .. "] missing the postbuild link-injector")

    local generated = require("create.templates.spa").files({ name = "x", router = router })
    generated = require("create.tailwind").apply(generated, { template = "spa", name = "x", router = router })
    assert(generated["package.json"]:find("inject%-tailwind%-link"), "[spa/" .. router .. "] build script must run the injector")
    assert(generated["src/styles.css"]:find('@source "./app.lua"', 1, true), "[spa/" .. router .. "] must scan app.lua for Tailwind classes")
    -- Neither router variant's moonstone.toml dev/build scripts are
    -- touched by --tailwind -- see create/tailwind.lua's own header
    -- comment for the two real, verified reasons `hydronium build/dev
    -- --vite` is not wired in for this CSS-only Vite config.
    assert(not generated["moonstone.toml"]:find("%-%-vite"), "[spa/" .. router .. "] must not alter the moon-run scripts")
  end
end)

test("create.scaffold honors an explicit --package-manager and rejects an unknown one", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-tailwind-pm", template = "islands", tailwind = true,
    package_manager = "bun", dry_run = true,
  })
  assert(res ~= nil, "explicit --package-manager bun should succeed: " .. tostring(err))
  assert(res.package_manager == "bun", "must honor the explicitly requested package manager")

  local res2, err2 = create.scaffold({
    directory = "/tmp/test-hydronium-tailwind-pm-bad", template = "islands", tailwind = true,
    package_manager = "yarn", dry_run = true,
  })
  assert(res2 == nil, "expected an unknown package manager to be refused")
  assert(err2:find("Unknown package manager", 1, true), tostring(err2))
end)

test("create.scaffold(--tailwind) is refused for templates with no Vite wiring", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-tailwind-ink", template = "ink", tailwind = true, dry_run = true,
  })
  assert(res == nil, "expected --tailwind to be refused for the ink template")
  assert(err:find("only supported for", 1, true), tostring(err))
end)

test("create.scaffold(--router hydronium) on islands adds the router site, dry-run", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-router-islands", template = "islands", name = "test-islands-router",
    router = "hydronium", dry_run = true,
  })
  assert(res ~= nil, "scaffold with --router hydronium failed: " .. tostring(err))
  local file_map = {}
  for _, f in ipairs(res.created) do file_map[f.path] = true end
  assert(file_map["views/Site.lua"], "missing views/Site.lua")
  assert(file_map["views/About.luax"], "missing views/About.luax")
  assert(res.router == "hydronium")
end)

test("create.scaffold(--router meteorite) on islands is a no-op (today's default)", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-router-meteorite", template = "islands", name = "test-islands-meteorite",
    router = "meteorite", dry_run = true,
  })
  assert(res ~= nil, "scaffold with --router meteorite failed: " .. tostring(err))
  local file_map = {}
  for _, f in ipairs(res.created) do file_map[f.path] = true end
  assert(not file_map["views/Site.lua"], "--router meteorite must not add a router site manifest")
  assert(res.router == "meteorite")
end)

test("create.scaffold(--router) rejects invalid combinations with clear errors", function()
  local res1, err1 = create.scaffold({ directory = "/tmp/x", template = "ssr", router = "meteorite", dry_run = true })
  assert(res1 == nil and err1:find("always uses Hydronium Router", 1, true), tostring(err1))

  local res2, err2 = create.scaffold({ directory = "/tmp/x", template = "minimal", router = "hydronium", dry_run = true })
  assert(res2 == nil and err2:find("only configurable for", 1, true), tostring(err2))

  local res3, err3 = create.scaffold({ directory = "/tmp/x", template = "islands", router = "bogus", dry_run = true })
  assert(res3 == nil and err3:find("Unknown router", 1, true), tostring(err3))
end)

test("CLI --tailwind and --router flags reach create.scaffold end to end", function()
  local handle = assert(io.popen([[lua ./src/main.lua /tmp/test-cli-tailwind-router --template islands --router hydronium --tailwind --dry-run 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local output = handle:read("*a")
  handle:close()
  assert(output:find("__EXIT__0", 1, true), output)
  assert(output:find("package.json", 1, true), output)
  assert(output:find("views/Site.lua", 1, true), output)
  assert(output:find("Tailwind CSS v4: enabled", 1, true), output)
  assert(output:find("Routing: hydronium", 1, true), output)
end)

-- Real scaffold (not dry-run) of every new tailwind/router combination,
-- with the same content-validity checks the base templates get below:
-- every .lua/.luax file actually loads/compiles, and every generated .js
-- file passes `node --check`. This is the regression gate for the new
-- code in tailwind.lua and router_mode.lua specifically.
test("tailwind and router-mode generated content actually parses/compiles", function()
  package.path = package.path .. ";../luax/src/?.lua;../luax/src/?/init.lua"
  local luax = require("hydronium_luax")
  local load_fn = loadstring or load

  local combos = {
    { dir = "/tmp/test-hydronium-content-gate-ssr-tailwind", template = "ssr", tailwind = true },
    { dir = "/tmp/test-hydronium-content-gate-islands-tailwind", template = "islands", tailwind = true },
    { dir = "/tmp/test-hydronium-content-gate-islands-router", template = "islands", router = "hydronium" },
    { dir = "/tmp/test-hydronium-content-gate-islands-router-tailwind", template = "islands", router = "hydronium", tailwind = true },
  }

  local node_available = os.execute("node --version >/dev/null 2>&1")
  node_available = node_available == true or node_available == 0

  for _, combo in ipairs(combos) do
    os.execute(string.format('rm -rf "%s" && mkdir -p "%s"', combo.dir, combo.dir))
    local res, err = create.scaffold({
      directory = combo.dir,
      template = combo.template,
      name = "content-gate-" .. combo.template,
      tailwind = combo.tailwind,
      router = combo.router,
      force = true,
    })
    assert(res ~= nil, "scaffold failed for " .. combo.dir .. ": " .. tostring(err))

    local checked_lua, checked_luax, checked_js = 0, 0, 0
    for _, f in ipairs(res.created) do
      if f.path:match("%.lua$") then
        local fh = assert(io.open(f.full_path, "r"))
        local content = fh:read("*a")
        fh:close()
        local chunk, load_err = load_fn(content, "@" .. f.full_path)
        assert(chunk, combo.dir .. " " .. f.path .. " failed to load as Lua: " .. tostring(load_err))
        checked_lua = checked_lua + 1
      elseif f.path:match("%.luax$") then
        local fh = assert(io.open(f.full_path, "r"))
        local content = fh:read("*a")
        fh:close()
        local ok, compile_result = pcall(function()
          return luax.compile(content, { filename = f.path, runtime = "hydronium", development = false })
        end)
        assert(ok, combo.dir .. " " .. f.path .. " failed to compile: " .. tostring(compile_result))
        checked_luax = checked_luax + 1
      elseif f.path:match("%.js$") and node_available then
        local result = os.execute(string.format('node --check "%s" >/dev/null 2>&1', f.full_path))
        assert(result == true or result == 0, combo.dir .. " " .. f.path .. " failed node --check")
        checked_js = checked_js + 1
      end
    end
    assert(checked_lua > 0, combo.dir .. ": no .lua files were checked")
    assert(checked_luax > 0, combo.dir .. ": no .luax files were checked")
    if combo.tailwind and node_available then
      assert(checked_js > 0, combo.dir .. ": vite.config.js was not syntax-checked")
    end

    os.execute(string.format('rm -rf "%s"', combo.dir))
  end
end)

--------------------------------------------------------------------------------
-- Ink Lab UI: create/src/create/ui/*.lua (the wizard's Ink presentation
-- layer, see hydronium.lab.lua's "create/src/create/ui" root) actually
-- load and render, via a REAL headless hydronium_ink.session -- the exact
-- same in-memory session hydronium-lab's Ink Lab protocol wraps (see
-- docs/HYDRONIUM_INK_LAB.md). Requires hydronium/core, hydronium/ink, and
-- hydronium/lab on this package's own path (see moonstone.toml's own
-- comment on why `create` -- a scaffolding CLI with nothing to do with
-- Ink at runtime -- depends on them at all: only these opt-in Lab stories
-- need them, never main.lua/wizard.lua).
--------------------------------------------------------------------------------

--- Shared by every wizard test below: dumps a session's current frame as
--- plain text, one row per line, trailing padding stripped.
local function wizard_text(sess)
  local frame = sess:frame()
  local out = {}
  for y = 1, #frame.rows do
    local row, chars = frame.rows[y], {}
    for x = 1, #row do chars[x] = (row[x] and row[x].ch) or " " end
    out[y] = table.concat(chars):gsub("%s+$", "")
  end
  return table.concat(out, "\n")
end

test("create.stories.lua loads and every story renders (honoring a story's own render override)", function()
  local session_mod = require("hydronium_ink.session")
  local collection = dofile("./src/create/ui/create.stories.lua")
  assert(collection.title == "Create/Wizard")

  local checked = 0
  for name, story in pairs(collection.stories) do
    if name ~= "install-flow" then
      local element = story.render and story.render(story.args or {}) or collection.render(story.args or {})
      local sizes = story.sizes or collection.sizes
      local size = sizes[1]
      local sess = session_mod.create(element, { columns = size.columns, rows = size.rows })
      local frame = sess:frame()
      assert(frame and frame.rows and #frame.rows > 0, "[" .. name .. "] produced an empty frame")
      sess:close()
      checked = checked + 1
    end
  end
  assert(checked >= 12, "expected every non-interactive story to render, checked only " .. checked)
end)

test("wizard header sweep is skippable by any key and expires on its own within 700ms", function()
  local session_mod = require("hydronium_ink.session")
  local hydronium = require("hydronium")
  local wizard_app = require("create.ui.wizard_app")

  -- The form is ALWAYS fully rendered, sweep or not (see wizard_app.lua's
  -- own header comment: there is no separate splash screen) -- what the
  -- sweep affects is only the header's gradient animation. This is
  -- verified indirectly: pressing a key during the sweep must not be
  -- swallowed as ordinary input into the (already-visible) name field, and
  -- the sweep must stop influencing anything within 700ms even with no
  -- key pressed at all, matching SWEEP_MS.
  local sess = session_mod.create(hydronium.h(wizard_app.create_wizard_app({ intro = true })), { columns = 84, rows = 130 })
  assert(wizard_text(sess):find("Project", 1, true), "the form must be visible from the very first frame, sweep or not")
  sess:write("x") -- the very first keypress during the sweep just dismisses it...
  sess:write("yz") -- ...so THIS is what actually reaches the name field
  assert(wizard_text(sess):find("yz", 1, true), "typing after the skip must reach the name field")
  assert(not wizard_text(sess):find("xyz", 1, true), "the key that dismissed the sweep must not also have been typed into the name field")
  sess:close()

  local timed = session_mod.create(hydronium.h(wizard_app.create_wizard_app({ intro = true })), { columns = 84, rows = 130 })
  timed:step(0); timed:step(750)
  -- After the sweep naturally expires, ordinary typing must work again.
  timed:write("ok")
  assert(timed:frame() ~= nil)
  timed:close()
end)

test("install-flow is a persistent, always-fully-rendered form (radios, toggles, rail, validation, resize)", function()
  local session_mod = require("hydronium_ink.session")
  local collection = dofile("./src/create/ui/create.stories.lua")

  local element = collection.render({ dry_run = true })
  local sess = session_mod.create(element, { columns = 84, rows = 130 })

  local initial = wizard_text(sess)
  assert(initial:find("Project", 1, true) and initial:find("Stack", 1, true)
    and initial:find("Styling", 1, true) and initial:find("Tooling", 1, true)
    and initial:find("Create", 1, true),
    "every section, and the final Create node, must be visible from the very first frame -- no separate review step")
  assert(initial:find("SSR", 1, true) and initial:find("SPA", 1, true)
    and initial:find("Islands", 1, true) and initial:find("Minimal", 1, true),
    "every framework alternative must always be visible")

  sess:write("test-lab-app")
  assert(wizard_text(sess):find("test%-lab%-app"), "typed name must appear immediately")

  -- ctrl+Enter with an otherwise-untouched form must not submit anything
  -- yet if navigation hasn't reached a fully valid state -- but since the
  -- name IS valid here, ctrl+Enter (or its ctrl+s fallback) must submit
  -- from ANYWHERE, not only from the final rail node.
  sess:write("\19") -- Ctrl+S: the documented, always-distinguishable fallback
  local after_submit = wizard_text(sess)
  assert(after_submit:find("Write project files", 1, true), "Ctrl+S must submit from anywhere, not only the final rail node")
  sess:close()

  -- A second run: walk fields explicitly, change the framework and
  -- router, toggle Tailwind, resize narrow, and confirm every value
  -- survives -- then submit from the final rail node with plain Enter.
  -- Navigation is STOP-based (see wizard_app.lua's own header comment):
  -- ↑/↓/←/→ move within a multi-option field's own vertically-stacked
  -- options first (matching how they're drawn), and only roll into the
  -- ADJACENT field once exhausted. Tab is the coarse "jump straight to
  -- the next field" alternative, used below whenever the intent is "done
  -- picking here, move on" rather than "change this field's pick".
  local sess2 = session_mod.create(collection.render({ dry_run = true }), { columns = 84, rows = 130 })
  sess2:write("router-app")
  sess2:write("\t")    -- name -> directory (Tab, coarse)
  sess2:write("\t")    -- directory -> framework (lands on its current pick: SSR)
  sess2:write("\27[C") -- framework: SSR -> SPA (fine, within the field)
  sess2:write("\t")    -- framework -> router (now enabled for SPA; lands on its current pick: Hydronium)
  sess2:write("\27[C") -- router: Hydronium -> Meteorite (fine, within the field)
  sess2:write("3")     -- digit jump to Styling
  sess2:write(" ")     -- toggle Tailwind on
  local mid = wizard_text(sess2)
  assert(mid:find("router%-app"), "the typed name must survive navigating away from it")
  assert(mid:find("\226\150\163 Tailwind CSS v4", 1, true), "Tailwind toggle must show as checked (\226\150\163) once turned on")

  sess2:resize(40, 130)
  local narrow = wizard_text(sess2)
  assert(narrow:find("router%-app"), "resizing narrower must not lose any typed value")
  assert(narrow:find("hydronium", 1, true), "the narrow header must fall back to the wordmark-only tier")

  sess2:resize(84, 130)
  sess2:write("4")     -- digit jump to Tooling (lands on package_manager's current pick)
  sess2:write("\t\t\t\t") -- package_manager -> interpreter -> install -> git -> submit (all coarse)
  sess2:write("\r")    -- Enter from the final rail node
  for step = 1, 6 do sess2:step(step * 150) end
  local final = wizard_text(sess2)
  assert(final:find("router%-app"), final)
  assert(final:find("\226\156\148 Write project files", 1, true), "the checklist must show the write step done")
  assert(final:find("%[DRY RUN%] Solution ready%.") or final:find("Files are written", 1, true), final)
  sess2:close()
end)

test("an empty project name blocks submit and is highlighted, from anywhere", function()
  local session_mod = require("hydronium_ink.session")
  local hydronium = require("hydronium")
  local wizard_app = require("create.ui.wizard_app")
  local sess = session_mod.create(hydronium.h(wizard_app.create_wizard_app({ dry_run = true })), { columns = 84, rows = 130 })

  sess:write("\27[B\27[B\27[B\27[B\27[B\27[B\27[B\27[B\27[B") -- navigate well away from the name field
  sess:write("\19") -- Ctrl+S from wherever we ended up
  local text = wizard_text(sess)
  assert(text:find("cannot be empty", 1, true), "an empty name must block submit with a visible error")
  assert(not text:find("Write project files", 1, true), "submit must not proceed with an invalid name")
  sess:close()
end)

test("package manager and router fields disable with a real reason when they don't apply", function()
  local session_mod = require("hydronium_ink.session")
  local hydronium = require("hydronium")
  local wizard_app = require("create.ui.wizard_app")
  -- SSR is the default framework: router is locked to Hydronium (SSR
  -- always uses it), and Tailwind/package manager stay whatever this
  -- machine's own detected managers allow -- this only asserts the
  -- router side, which is unconditional.
  local sess = session_mod.create(hydronium.h(wizard_app.create_wizard_app({ dry_run = true, name = "x" })), { columns = 84, rows = 130 })
  local text = wizard_text(sess)
  assert(text:find("SSR always uses Hydronium Router", 1, true), "router must show why it's locked for the default SSR framework")
  -- Field-level reasons print ONCE, not once per option -- and each
  -- option keeps its own real description regardless.
  local _, count = text:gsub("SSR always uses Hydronium Router", "")
  assert(count == 1, "the router disabled reason must print exactly once, not per option: " .. text)
  assert(text:find("Typed routes and client%-side navigation", 1, false), "each option must keep its own description even while the field is disabled")
  assert(text:find("One server%-declared route, no router manifest", 1, false), "each option must keep its own description even while the field is disabled")
  sess:close()
end)

test("directory follows the typed name until edited directly, and reflects the real CLI default otherwise", function()
  local session_mod = require("hydronium_ink.session")
  local hydronium = require("hydronium")
  local wizard_app = require("create.ui.wizard_app")

  -- With no name typed yet, the field shows a dim placeholder plus the
  -- cursor -- never a bare blank line -- and directory reflects the real,
  -- literal default `create/src/main.lua` uses when no --directory is
  -- given at all (`ctx.args.directory or "."`, i.e. scaffold IN the
  -- current directory): "." -- NOT "./<name>", since there is no name yet.
  local sess = session_mod.create(hydronium.h(wizard_app.create_wizard_app({ dry_run = true })), { columns = 84, rows = 130 })
  local initial = wizard_text(sess)
  assert(initial:find("my%-app\226\150\141", 1, false) or initial:find("my%-app", 1, true), "an empty name must show a dim placeholder plus the cursor")
  assert(initial:find("directory  %.", 1, false), "directory must read the real CLI default (\".\") before any name is typed: " .. initial)

  -- Typing a name updates directory LIVE to "./<name>" (a deliberate wizard
  -- convenience, NOT a rediscovery of the plain CLI's own "." default --
  -- see wizard_app.lua's own comment on this).
  sess:write("acid-app")
  local after_name = wizard_text(sess)
  assert(after_name:find("directory  %./acid%-app", 1, false), "directory must live-follow the typed name: " .. after_name)

  -- Editing directory directly stops it from following the name any further.
  sess:write("\t") -- name -> directory
  sess:write("-custom")
  local after_edit = wizard_text(sess)
  assert(after_edit:find("%./acid%-app%-custom", 1, false), after_edit)
  sess:write("\t\t") -- directory -> framework -> ... back to name (wraps or lands elsewhere; just go back explicitly)
  sess:close()

  -- A second session: editing directory FIRST (appending onto its "."
  -- default -- text fields here are append/backspace-only, never
  -- select-on-focus, matching every other field in this wizard), then
  -- typing a name, must never overwrite the manually-typed directory.
  local sess2 = session_mod.create(hydronium.h(wizard_app.create_wizard_app({ dry_run = true })), { columns = 84, rows = 130 })
  sess2:write("\t") -- name -> directory
  sess2:write("somewhere-else")
  sess2:write("\27[Z") -- Shift+Tab back to name
  sess2:write("later-name")
  local final = wizard_text(sess2)
  assert(final:find("somewhere%-else"), "a manually-typed directory must never be overwritten by a later name edit: " .. final)
  assert(not final:find("%./later%-name", 1, false), final)
  sess2:close()
end)

test("vertical option-stop navigation: up/down pick within a field, then roll into the adjacent field preserving its own selection", function()
  local session_mod = require("hydronium_ink.session")
  local hydronium = require("hydronium")
  local wizard_app = require("create.ui.wizard_app")
  local sess = session_mod.create(hydronium.h(wizard_app.create_wizard_app({ dry_run = true, name = "x" })), { columns = 84, rows = 200 })

  -- Pick SPA explicitly (Tab to framework, then step down once: SSR -> SPA).
  -- SPA supports router/Tailwind, so it stays the field ↓/↑ can roll into
  -- and out of cleanly for the rest of this test (Minimal/Ink/LÖVE would
  -- disable router entirely, which is covered by its own test).
  sess:write("\t") -- name -> directory
  sess:write("\t") -- directory -> framework (lands on current pick: SSR)
  sess:write("\27[B") -- SSR -> SPA
  assert(wizard_text(sess):find("\226\151\137 SPA", 1, true), "down from SSR must select SPA")

  -- Coarse-jump to router (Tab) and pick Meteorite (fine, within router).
  sess:write("\t") -- framework -> router (lands on router's current pick: Hydronium)
  assert(wizard_text(sess):find("\226\151\137 Hydronium Router", 1, true), "Tab must land on router's OWN current pick")
  sess:write("\27[B") -- Hydronium -> Meteorite
  assert(wizard_text(sess):find("\226\151\137 Meteorite only", 1, true), "down within router must select Meteorite")

  -- Coarse-jump forward to Tailwind (a single-stop field), then roll
  -- BACKWARD (↑) off it -- this must land on ROUTER's CURRENT pick
  -- (Meteorite, just chosen above), never reset it back to Hydronium.
  sess:write("\t") -- router -> tailwind
  sess:write("\27[A") -- rolls back into router
  local rolled_back = wizard_text(sess)
  assert(rolled_back:find("\226\151\137 Meteorite only", 1, true), "rolling back into router must preserve ITS current pick (Meteorite), not reset it: " .. rolled_back)

  -- One more ↑ moves WITHIN router (Meteorite -> Hydronium); one more
  -- after that rolls further back into FRAMEWORK's current pick (SPA),
  -- never resetting it back to SSR.
  sess:write("\27[A") -- Meteorite -> Hydronium (within router)
  assert(wizard_text(sess):find("\226\151\137 Hydronium Router", 1, true))
  sess:write("\27[A") -- rolls back into framework
  local back_in_framework = wizard_text(sess)
  assert(back_in_framework:find("\226\151\137 SPA", 1, true), "rolling back into framework must preserve ITS current pick (SPA), not reset to SSR: " .. back_in_framework)
  sess:close()
end)

test("Ink and LÖVE lock the interpreter to LuaJIT, with a visible per-option disabled reason", function()
  local session_mod = require("hydronium_ink.session")
  local hydronium = require("hydronium")
  local wizard_app = require("create.ui.wizard_app")
  local sess = session_mod.create(hydronium.h(wizard_app.create_wizard_app({
    dry_run = true, name = "x", initial_framework_id = "ink",
  })), { columns = 84, rows = 200 })
  local text = wizard_text(sess)
  assert(text:find("Ink requires LuaJIT", 1, true), "Lua 5.4 must show why it's locked out under Ink: " .. text)
  assert(text:find("\226\151\137 LuaJIT 2%.1", 1, false), "LuaJIT must remain the (only real) pick under Ink")
  sess:close()

  local sess2 = session_mod.create(hydronium.h(wizard_app.create_wizard_app({
    dry_run = true, name = "x", initial_framework_id = "love",
  })), { columns = 84, rows = 200 })
  local text2 = wizard_text(sess2)
  assert(text2:find("LÖVE requires LuaJIT", 1, true), "Lua 5.4 must show why it's locked out under LÖVE: " .. text2)
  sess2:close()

  -- Switching INTO a locked framework from one where Lua 5.4 was actually
  -- picked must auto-correct the interpreter back to LuaJIT, since
  -- create.scaffold itself rejects Ink/LÖVE with any other interpreter.
  local sess3 = session_mod.create(hydronium.h(wizard_app.create_wizard_app({
    dry_run = true, name = "x", initial_interpreter_id = "lua@5.4",
  })), { columns = 84, rows = 200 })
  assert(wizard_text(sess3):find("\226\151\137 Lua 5%.4", 1, false), "sanity: Lua 5.4 must start selected")
  sess3:write("\t\t") -- name -> directory -> framework
  sess3:write("\27[C\27[C\27[C\27[C") -- SSR -> spa -> islands -> minimal -> ink
  local corrected = wizard_text(sess3)
  assert(corrected:find("\226\151\137 Ink", 1, true), "sanity: framework must actually be Ink now: " .. corrected)
  assert(corrected:find("\226\151\137 LuaJIT 2%.1", 1, false), "switching to Ink must auto-correct an incompatible interpreter pick back to LuaJIT: " .. corrected)
  sess3:close()
end)

test("strikethrough on unpicked radio options is real at the terminal-cell level, not just a rendered label", function()
  local session_mod = require("hydronium_ink.session")
  local hydronium = require("hydronium")
  local wizard_app = require("create.ui.wizard_app")
  local sess = session_mod.create(hydronium.h(wizard_app.create_wizard_app({ dry_run = true, name = "x" })), { columns = 84, rows = 200 })
  -- Move off the framework field entirely (into router) so it is no
  -- longer the "actively edited" field -- struck-through rendering only
  -- applies to NON-picked alternatives once their field is no longer
  -- being edited (see ui/field.lua's own header comment). SSR itself is
  -- the actual pick here (the default) and must therefore stay UNSTRUCK
  -- even while inactive -- only its sibling alternatives (e.g. SPA) get
  -- struck through, which is the real thing worth checking at the cell
  -- level.
  sess:write("\t") -- name -> directory
  sess:write("\t") -- directory -> framework (SSR is the active field now)
  sess:write("\t") -- framework -> router: framework is no longer the active field

  local frame = sess:frame()
  local found_struck_spa, found_unstruck_ssr = false, false
  for _, row in ipairs(frame.rows) do
    local line_chars = {}
    for x = 1, #row do line_chars[x] = (row[x] and row[x].ch) or " " end
    local line = table.concat(line_chars)
    if line:find("SPA", 1, true) then
      for x = 1, #row do
        local cell = row[x]
        if cell and cell.ch == "S" then
          assert(cell.strikethrough == true, "the unpicked SPA option must be struck through at the cell level once its field is no longer active: " .. line)
          assert(cell.dim == true, "a struck-through option must also be dim")
          found_struck_spa = true
        end
      end
    elseif line:find("SSR", 1, true) then
      for x = 1, #row do
        local cell = row[x]
        if cell and cell.ch == "S" then
          assert(cell.strikethrough ~= true, "the ACTUAL pick (SSR) must never be struck through, even while its field is inactive: " .. line)
          found_unstruck_ssr = true
        end
      end
    end
  end
  assert(found_struck_spa, "did not find the SPA option row to check at all")
  assert(found_unstruck_ssr, "did not find the SSR option row to check at all")
  sess:close()
end)

--------------------------------------------------------------------------------
-- Content-validity regression gate.
--
-- Everything above this line only ever checked WHICH files get created,
-- never whether their CONTENT was valid Lua/LUAX or a valid moonstone.toml
-- -- exactly how all four templates shipped broken (arrow-function syntax
-- that doesn't exist in LUAX, a fictional Meteorite API, a bare
-- `[dependencies]` table header invalid for manifest_version 2, ...) for a
-- full audit cycle with a fully green test suite the whole time. This test
-- scaffolds every template for real and actually loads/compiles every
-- generated file, so a template that regresses back into "creates files
-- that don't parse" fails HERE, not in a human's hands.
--
-- Real, observed history of this exact test (not hypothetical): before
-- templates/ssr.lua and templates/islands.lua were rewritten, this test
-- failed red on both -- ssr.lua's `views/App.luax` used `() => ...` arrow
-- functions hydronium_luax.compile rejects outright, and islands.lua's
-- `moonstone.toml` had no bare `[dependencies]` bug (it used the equally
-- fictional `{path = "../hydronium"}` object form under `[dependencies]`,
-- which IS a bare single-bracket header) -- and passed green only after
-- those templates were fixed to use the real Meteorite/Hydronium APIs
-- verified via a live build/run/curl (ssr) and a live build/run/Playwright
-- click (islands).
--------------------------------------------------------------------------------

test("every template's generated content actually parses/compiles (content-validity gate)", function()
  -- The compiler is now an independent library package with its own top-level
  -- namespace, matching the module identity Moonstone materializes for
  -- generated projects.
  package.path = package.path .. ";../luax/src/?.lua;../luax/src/?/init.lua"
  local luax = require("hydronium_luax")
  local load_fn = loadstring or load

  local function has_bare_dependencies_header(toml_content)
    for line in toml_content:gmatch("[^\n]+") do
      -- Matches a bare `[dependencies]` line but NOT `[[dependencies]]`
      -- (the real, only-valid array-of-tables form for manifest_version 2)
      -- -- the leading `^%[` would also match the first `[` of `[[`, so
      -- this specifically rejects a second `[` or a non-`]` character
      -- right after the tag name from counting as a match.
      local trimmed = line:gsub("%s+$", "")
      if trimmed:match("^%[dependencies%]$") then
        return true
      end
    end
    return false
  end

  local templates = create.available_templates()
  assert(#templates > 0, "no templates to validate")

  for _, tmpl in ipairs(templates) do
    local dir = "/tmp/test-hydronium-content-gate-" .. tmpl.id
    os.execute(string.format('rm -rf "%s" && mkdir -p "%s"', dir, dir))

    local res, err = create.scaffold({
      directory = dir,
      template = tmpl.id,
      name = "content-gate-" .. tmpl.id,
      force = true,
    })
    assert(res ~= nil, "scaffold failed for template '" .. tmpl.id .. "': " .. tostring(err))

    local checked_lua, checked_luax, checked_js, checked_toml = 0, 0, 0, 0
    local ink_refresh_descriptors = 0

    for _, f in ipairs(res.created) do
      if f.path:match("%.lua$") then
        local fh = assert(io.open(f.full_path, "r"), "could not open " .. f.full_path)
        local content = fh:read("*a")
        fh:close()
        local chunk, load_err = load_fn(content, "@" .. f.full_path)
        assert(chunk, "[" .. tmpl.id .. "] " .. f.path .. " failed to load as Lua: " .. tostring(load_err))
        checked_lua = checked_lua + 1
      elseif f.path:match("%.luax$") then
        local fh = assert(io.open(f.full_path, "r"), "could not open " .. f.full_path)
        local content = fh:read("*a")
        fh:close()
        local ok, compile_result = pcall(function()
          return luax.compile(content, { filename = f.path, runtime = "hydronium", development = false })
        end)
        assert(ok, "[" .. tmpl.id .. "] " .. f.path .. " failed to compile: " .. tostring(compile_result))
        if tmpl.id == "ink" and f.path == "src/app.luax" then
          ink_refresh_descriptors = compile_result.refresh and compile_result.refresh.rewritten or 0
        end
        checked_luax = checked_luax + 1
      elseif f.path:match("%.js$") then
        local result = os.execute(string.format('node --check "%s" >/dev/null 2>&1', f.full_path))
        assert(result == true or result == 0, "[" .. tmpl.id .. "] " .. f.path .. " failed node --check")
        checked_js = checked_js + 1
      elseif f.path == "moonstone.toml" then
        local fh = assert(io.open(f.full_path, "r"), "could not open " .. f.full_path)
        local content = fh:read("*a")
        fh:close()
        assert(not has_bare_dependencies_header(content),
          "[" .. tmpl.id .. "] moonstone.toml has a bare [dependencies] table header -- only [[dependencies]] is valid for manifest_version = 2")
        checked_toml = checked_toml + 1
      end
    end

    assert(checked_lua > 0, "[" .. tmpl.id .. "] no .lua files were checked -- test may be miswired")
    assert(checked_toml == 1, "[" .. tmpl.id .. "] expected exactly one moonstone.toml, checked " .. checked_toml)

    local manifest_file = assert(io.open(dir .. "/moonstone.toml", "r"))
    local manifest = manifest_file:read("*a")
    manifest_file:close()
    assert(not manifest:find("symlink_to", 1, true), "[" .. tmpl.id .. "] manifest must not use source symlinks")
    assert(manifest:find('name = "hydronium/core"', 1, true), "[" .. tmpl.id .. "] missing hydronium core dependency")
    if tmpl.id == "ssr" or tmpl.id == "islands" then
      assert(manifest:find('name = "hydronium/luax"', 1, true), "[" .. tmpl.id .. "] missing hydronium/luax dependency")
      assert(manifest:find('name = "hydronium/dom"', 1, true), "[" .. tmpl.id .. "] missing hydronium/dom dependency")
      if tmpl.id == "islands" then
        assert(checked_js > 0, "[islands] no generated browser JavaScript was syntax-checked")
      end
    elseif tmpl.id == "ink" then
      assert(checked_luax > 0, "[ink] no .luax files were compiled")
      assert(ink_refresh_descriptors > 0, "[ink] App signal is not eligible for state-preserving HMR")
      assert(manifest:find('name = "hydronium/ink"', 1, true), "[ink] missing hydronium/ink dependency")
      do
        local ink_constraint = manifest:match('name = "hydronium/ink"\nconstraint = "([^"]+)"')
        assert(ink_constraint, "[ink] could not find hydronium/ink's own constraint line")
        local real_ink_version = sibling_package_version("../ink/moonstone.toml")
        assert(satisfies_caret(real_ink_version, ink_constraint),
          string.format("[ink] template declares hydronium/ink %s, which does not admit the real current hydronium/ink %s -- bump templates/ink.lua's constraint",
            ink_constraint, real_ink_version))
      end
      assert(manifest:find('name = "hydronium/luax"', 1, true), "[ink] missing hydronium/luax dependency")
      assert(manifest:find('name = "luajit"', 1, true), "[ink] interpreter must be LuaJIT")
      assert(manifest:find('version = "2.1.0"', 1, true), "[ink] must select LuaJIT 2.1.0")
      assert(manifest:find('abi = "5.1"', 1, true), "[ink] must select Lua ABI 5.1")
      -- Was a hardcoded `constraint = "^0.1.0"` literal check -- itself
      -- stale (nothing in this template has used that exact value for a
      -- long time; it was masked by the hydronium/ink assertion above
      -- failing first and short-circuiting this whole `test()` block
      -- before execution ever reached this line). The actual intent, per
      -- the two negative checks right below, is just "every dependency
      -- uses a real registry caret constraint, never a monorepo path
      -- override" -- checked structurally instead of against one
      -- version number this file would otherwise have to keep updated by
      -- hand forever.
      assert(manifest:find('constraint = "%^%d+%.%d+%.%d+"'), "[ink] dependencies must use portable registry constraints")
      assert(not manifest:find('registry = "path"', 1, true), "[ink] must not require a monorepo checkout")
      assert(not manifest:find('path:', 1, true), "[ink] must not emit path constraints")
    elseif tmpl.id == "love" then
      assert(manifest:find('name = "luajit"', 1, true), "[love] must select LuaJIT")
      assert(manifest:find('version = "2.1.0"', 1, true), "[love] must select LuaJIT 2.1")
      assert(manifest:find('abi = "5.1"', 1, true), "[love] must target LÖVE's Lua 5.1 ABI")
      assert(manifest:find('name = "moonstone/ballad"', 1, true), "[love] must package with Ballad")
      assert(manifest:find('package = "moon exec %-%- ballad play partiture.lua"'), "[love] missing package script")
    elseif tmpl.id == "spa" then
      -- Default (no --router given) is the "hydronium" variant -- see
      -- create.scaffold's own comment on why spa needs its router choice
      -- as an INPUT to .files(), unlike islands' post-hoc transform.
      assert(manifest:find('name = "hydronium/ballad"', 1, true), "[spa] missing hydronium/ballad (the real client bundler)")
      assert(manifest:find('name = "hydronium/router"', 1, true), "[spa] default router variant must bundle hydronium/router")
      assert(not manifest:find('path:', 1, true), "[spa] must not emit path constraints")
      assert(not manifest:find('registry = "path"', 1, true), "[spa] must not require a monorepo checkout")
    end

    local luals_file = assert(io.open(dir .. "/.luarc.json", "r"))
    local luals_config = luals_file:read("*a")
    luals_file:close()
    if tmpl.id ~= "ink" and tmpl.id ~= "love" then
      assert(luals_config:find("libexec/dom/types", 1, true), "[" .. tmpl.id .. "] missing packaged DOM types")
    else
      assert(luals_config:find("share/lua/5%.1"), "[" .. tmpl.id .. "] missing LuaJIT workspace library")
      assert(not luals_config:find("libexec/dom/types", 1, true), "[" .. tmpl.id .. "] must not configure DOM types")
    end
    if tmpl.id == "minimal" or tmpl.id == "love" or tmpl.id == "spa" then
      assert(not luals_config:find("hydronium_luax", 1, true), "[" .. tmpl.id .. "] must not configure an unavailable LUAX plugin")
      assert(not luals_config:find("ambient%-types"), "[" .. tmpl.id .. "] must not opt into bare DOM globals")
    else
      assert(luals_config:find("hydronium_luax/luals/init.lua", 1, true), "[" .. tmpl.id .. "] missing LUAX plugin")
      assert(luals_config:find("libexec/luax/types", 1, true), "[" .. tmpl.id .. "] missing packaged LUAX types")
      if tmpl.id == "ink" then
        assert(not luals_config:find("ambient%-types"), "[ink] must not configure ambient DOM globals")
      else
        assert(luals_config:find("ambient%-types"), "[" .. tmpl.id .. "] missing bare DOM globals")
      end
    end

    os.execute(string.format('rm -rf "%s"', dir))
  end
end)

test("update_check picks the newest stable version from a registry index, per package", function()
  local update = require("create.update_check")
  local index = table.concat({
    '[[package]]', 'name = "hydronium/create"', 'version = "0.4.1"', '',
    '[[package]]', 'name = "hydronium/create"', 'version = "0.10.0"', '',
    '[[package]]', 'name = "hydronium/create"', 'version = "1.0.0-rc.1"', '',
    '[[package]]', 'name = "hydronium/cli"', 'version = "9.9.9"', '',
  }, "\n")
  assert(update.latest_from_index(index) == "0.10.0", "numeric (not lexical) ordering, prereleases and other packages ignored")
  assert(update.newer("0.10.0", "0.9.9") and not update.newer("0.5.0", "0.5.0"))
end)

test("update_check never claims a status without data and refreshes stale caches in the background", function()
  local update = require("create.update_check")
  local env = { HOME = "/home/u" }
  local function getenv(k) return env[k] end
  local commands = {}
  local function execute(cmd) commands[#commands + 1] = cmd; return true end
  local index = '[[package]]\nname = "hydronium/create"\nversion = "0.6.0"\n'

  -- No cache yet: unknown (nil), and a detached refresh is started.
  assert(update.check("0.5.0", { getenv = getenv, execute = execute, age = function() return nil end }) == nil)
  assert(#commands == 1 and commands[1]:find("/index.toml", 1, true) and commands[1]:find("&$"), "refresh must be detached")
  assert(commands[1]:find("/home/u/.cache/hydronium/", 1, true))

  -- Fresh cache: answers from it without refreshing.
  commands = {}
  local status = update.check("0.5.0", { getenv = getenv, execute = execute, age = function() return 60 end, read_file = function() return index end })
  assert(status and status.available and status.latest == "0.6.0" and #commands == 0)
  status = update.check("0.6.0", { getenv = getenv, execute = execute, age = function() return 60 end, read_file = function() return index end })
  assert(status and not status.available)

  -- Stale cache: still answers from it, and refreshes for next time.
  update.check("0.5.0", { getenv = getenv, execute = execute, age = function() return update.TTL_SECONDS + 1 end, read_file = function() return index end })
  assert(#commands == 1)

  -- Disabled in CI / by opt-out: no status, no network.
  commands = {}
  env.CI = "true"
  assert(update.check("0.5.0", { getenv = getenv, execute = execute, age = function() return 60 end, read_file = function() return index end }) == nil)
  assert(#commands == 0)
end)

test("update_check.start reports checking while fetching, then settles (or falls back on timeout)", function()
  local update = require("create.update_check")
  local env = { HOME = "/home/u" }
  local files, clock, commands = {}, 1000, {}
  local opts = {
    getenv = function(k) return env[k] end,
    execute = function(cmd) commands[#commands + 1] = cmd; return true end,
    read_file = function(p) return files[p] end,
    remove = function(p) files[p] = nil end,
    age = function() return nil end,
    now = function() return clock end,
  }
  local index = '[[package]]\nname = "hydronium/create"\nversion = "0.6.0"\n'
  local cache = update.cache_path(opts.getenv)

  local handle = update.start("0.5.0", opts)
  assert(#commands == 1, "a missing cache starts exactly one background fetch")
  local marker = commands[1]:match("echo %$%? > '([^']+)'")
  assert(marker, "the fetch reports completion through a marker file")
  assert(handle.poll().state == "checking")
  files[cache], files[marker] = index, "0\n"
  local status = handle.poll()
  assert(status.state == "available" and status.latest == "0.6.0")
  assert(files[marker] == nil, "marker is cleaned up")

  -- Offline with no cache: after the timeout the answer is unknown (nil).
  files, commands = {}, {}
  local offline = update.start("0.5.0", opts)
  assert(offline.poll().state == "checking")
  clock = clock + update.TIMEOUT_SECONDS + 3
  assert(offline.poll() == nil, "never claims a status without data")

  -- Fresh cache answers immediately, no network.
  commands = {}
  opts.age = function() return 60 end
  files[cache] = index
  assert(update.start("0.6.0", opts).poll().state == "current" and #commands == 0)
end)

test("update status badge follows the breakpoints: icon + label, icon + short, icon only", function()
  local session_mod = require("hydronium_ink.session")
  local logo = require("create.ui.logo")
  local function text(state, columns)
    local sess = session_mod.create(logo.render({ columns = columns, version = "0.5.0", frame = 0, update_status = state }), { columns = columns, rows = 1 })
    local chars = {}
    for x, cell in ipairs(sess:frame().rows[1]) do chars[x] = cell.ch or " " end
    sess:close()
    return table.concat(chars)
  end
  local checking, available, current = { state = "checking" }, { state = "available", latest = "0.6.0" }, { state = "current" }
  assert(text(checking, 84):find("Checking for updates", 1, true))
  assert(text(checking, 70):find("Checking…", 1, true) and not text(checking, 70):find("updates", 1, true))
  assert(text(available, 84):find(" !  Update available v0.6.0", 1, true))
  assert(text(available, 70):find(" !  v0.6.0", 1, true) and not text(available, 70):find("Update available", 1, true))
  assert(text(available, 50):find(" ! ", 1, true) and not text(available, 50):find("v0.6.0", 1, true))
  assert(text(current, 84):find(" ✓  Up to date", 1, true))
  assert(text(current, 70):find(" ✓ ", 1, true) and not text(current, 70):find("Up to date", 1, true))
  assert(not text(nil, 84):find("✓", 1, true) and not text(nil, 84):find("!", 1, true), "unknown shows nothing")
  assert(not text(current, 36):find("✓", 1, true), "below 40 columns there is no status")
end)

test("bubble diorama: seeded closed-form motion, depth layering around the title", function()
  local session_mod = require("hydronium_ink.session")
  local bubbles = require("create.ui.bubbles")
  local logo = require("create.ui.logo")
  -- Deterministic and width-stable: a wider band keeps every existing lane.
  local narrow, wide = bubbles.field(84, 1800), bubbles.field(120, 1800)
  local key = function(b) return b.col .. ":" .. b.row .. ":" .. b.ch end
  local in_wide = {}
  for _, b in ipairs(wide) do in_wide[key(b)] = true end
  for _, b in ipairs(narrow) do assert(in_wide[key(b)], "resizing must not reshuffle existing lanes") end
  -- Scan time for a near bubble and a behind bubble on the title row, and
  -- check the painted cell: near overwrites the text, behind never does.
  local function row3(t)
    local sess = session_mod.create(bubbles.render_diorama({ time = t, columns = 84 },
      logo.render({ columns = 84, version = "0.5.0" })), { columns = 84, rows = bubbles.ROWS })
    local cells = sess:frame().rows[bubbles.TITLE_ROW]
    local out = {}
    for x, cell in ipairs(cells) do out[x] = cell.ch or " " end
    sess:close()
    return out
  end
  local base = {}
  do
    local sess = session_mod.create(logo.render({ columns = 84, version = "0.5.0" }), { columns = 84, rows = 1 })
    for x, cell in ipairs(sess:frame().rows[1]) do base[x] = cell.ch or " " end
    sess:close()
  end
  local saw_front, saw_behind = false, false
  for t = 0, 30000, 60 do
    for _, b in ipairs(bubbles.field(84, t)) do
      if b.row == bubbles.TITLE_ROW and base[b.col] ~= " " then
        local painted = row3(t)[b.col]
        if bubbles.in_front(b) then
          assert(painted == b.ch, "a near bubble is drawn in front of the title")
          saw_front = true
        else
          assert(painted == base[b.col], "mid/far bubbles stay behind the title text")
          saw_behind = true
        end
      end
    end
    if saw_front and saw_behind then break end
  end
  assert(saw_front and saw_behind, "expected both layering cases within 30s of motion")
end)

print(string.format("\nResults: %d/%d passed\n", passed, total))
if passed < total then
  os.exit(1)
end
