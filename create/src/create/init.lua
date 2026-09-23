local writer = require("create.writer")
local luals = require("create.luals")
local process = require("create.process")
local jsonc = require("alter_jsonc")

local create = {}

local template_order = { "ssr", "islands", "minimal", "ink", "love" }
local template_specs = {
  ssr = {
    module = require("create.templates.ssr"),
    name = "SSR (Hydronium + Meteorite)",
    description = "SSR document with a persistent browser Lua VM and component HMR",
    -- `meteorite = true` puts Meteorite's generated LuaCATS aids
    -- (.meteorite/aids/lua) on the LuaLS path. Without it those files are
    -- generated on every `meteorite graph`/`build` but never reach the
    -- editor -- see luals.lua's comment for the verified before/after.
    tooling = { luax = true, dom = true, bare_dom = true, meteorite = true },
    next_script = "dev",
  },
  islands = {
    module = require("create.templates.islands"),
    name = "Islands Architecture",
    description = "Server-rendered shell with a real, client-hydrated JS island",
    tooling = { luax = true, dom = true, bare_dom = true, meteorite = true },
    next_script = "dev",
  },
  minimal = {
    module = require("create.templates.minimal"),
    name = "Minimal Component",
    description = "Barebones reactive component for embedding or scripting",
    tooling = { luax = false, dom = true, bare_dom = false },
    next_script = "run",
    cli_flag = true,
  },
  ink = {
    module = require("create.templates.ink"),
    name = "Ink Terminal App",
    description = "Interactive terminal UI with Yoga layout and keyboard input",
    tooling = { luax = true, dom = false, bare_dom = false },
    interpreters = { "luajit@2.1" },
    runtime_reason = "hydronium-ink uses LuaJIT FFI for terminal layout",
    next_script = "run",
  },
  love = {
    module = require("create.templates.love"),
    name = "LÖVE Game",
    description = "LÖVE game loop with topology-backed controlled HMR remounts",
    tooling = { luax = false, dom = false, bare_dom = false },
    interpreters = { "luajit@2.1" },
    runtime_reason = "LÖVE embeds LuaJIT/Lua 5.1; the `love` executable remains a host prerequisite",
    next_script = "run",
  },
}

-- Load the disabled template so syntax regressions remain visible even though
-- it is not advertised or scaffoldable yet.
require("create.templates.spa")

-- `spa` is intentionally excluded here (and from src/main.lua's
-- `--template` completion list) -- see templates/spa.lua's own header
-- comment for why. Root mounting and client bundling now exist; routing and
-- a server-less delivery contract remain the blockers. The file stays on disk
-- so those prerequisites remain attached to the disabled template.
function create.available_templates()
  local result = {}
  for _, id in ipairs(template_order) do
    local spec = template_specs[id]
    result[#result + 1] = { id = id, name = spec.name, description = spec.description }
  end
  return result
end

function create.template_ids()
  local result = {}
  for _, id in ipairs(template_order) do
    if not template_specs[id].cli_flag then result[#result + 1] = id end
  end
  return result
end

local function shell_quote(str)
  return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

--- Distinguishes "the directory has real entries in it" from "the
--- directory doesn't exist yet" -- `ls -A` on a nonexistent path also
--- reads as empty (empty stdout, nonzero exit swallowed by the `2>/dev/null`
--- redirect), which previously made the two cases indistinguishable and
--- meant a scaffold into a path with a missing parent silently skipped
--- the non-empty-directory guard instead of just proceeding (a fresh
--- directory is legitimately fine to scaffold into either way, but for
--- the right reason, not an accident of `ls`'s error behavior).
local function directory_exists(dir)
  local test_handle = io.popen(string.format("[ -d %s ] && echo yes || echo no", shell_quote(dir)))
  if not test_handle then return false end
  local out = test_handle:read("*l")
  test_handle:close()
  return out == "yes"
end

local function is_directory_empty(dir)
  if not directory_exists(dir) then
    return true
  end
  local handle = io.popen(string.format("ls -A %s 2>/dev/null", shell_quote(dir)))
  if not handle then return true end
  local output = handle:read("*a")
  handle:close()
  if not output or output:match("^%s*$") then
    return true
  end
  return false
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  local ok, write_err = file:write(content)
  file:close()
  if not ok then return nil, write_err end
  return true
end

local function love_compatible_abi(abi)
  return abi == "5.1" or abi == "lua51" or abi == "lua-5.1"
end

local function manifest_from_export(output)
  local document, err = jsonc.parse(output or "")
  if not document then return nil, tostring(err and err.message or err or "invalid JSON") end
  local manifest = document:value_at({ "manifest" })
  if type(manifest) ~= "table" then return nil, "Moonstone returned no manifest" end
  return manifest
end

--- Add Hydronium to an existing LÖVE project. The dependency is changed only
--- through Moonstone; the bridge deliberately leaves the game's entrypoint
--- and editor configuration alone.
function create.add_love(opts)
  opts = opts or {}
  local target_dir = opts.directory or "."
  local files = template_specs.love.module.addon_files()
  -- Refuse before invoking Moonstone so an existing bridge never leaves a
  -- project with a surprising dependency-only partial result.
  for path in pairs(files) do
    local existing = io.open((target_dir .. "/" .. path):gsub("/+", "/"), "r")
    if existing then
      existing:close()
      return nil, "Refusing to overwrite existing file " .. path
    end
  end

  local planned_commands = {
    { "moon", "add", "--role", "runtime", "--no-sync", "hydronium/core" },
    { "moon", "add", "--tool", "--no-sync", "moonstone/ballad" },
    { "moon", "manifest", "script", "set", "love-dev", "--command", "love ." },
    { "moon", "manifest", "script", "set", "love-package", "--command", "moon exec -- ballad play hydronium.love.partiture.lua" },
    { "moon", "sync" },
  }
  if opts.dry_run then
    local results, err = (opts.write_project or writer.write_project)(target_dir, files, { dry_run = true, no_overwrite = true })
    if not results then return nil, err end
    return {
      project_name = opts.name or (target_dir:match("([^/]+)/?$") or "existing-love-project"),
      target_dir = target_dir, template = "love-addon", created = results.created,
      next_script = "love-dev", package_script = "love-package", dry_run = true,
      additive = true, commands = planned_commands,
    }
  end

  if not directory_exists(target_dir) then
    return nil, "--add-love expects an existing LÖVE project directory: " .. target_dir
  end
  local main = io.open((target_dir .. "/main.lua"):gsub("/+", "/"), "r")
  if not main then return nil, "No main.lua found; --add-love only augments an existing LÖVE project" end
  main:close()

  local moon = opts.moon or os.getenv("MOONSTONE_CLI") or os.getenv("MOONSTONE_BIN") or "moon"
  local run = opts.run_process or process.capture
  local manifest_path = (target_dir .. "/moonstone.toml"):gsub("/+", "/")
  local original_manifest = read_file(manifest_path)
  local initialized = original_manifest == nil
  local project_name = opts.name or (target_dir:match("([^/]+)/?$") or "existing-love-project")

  local function invoke(args)
    local result = run({ tool = moon, args = args, cwd = target_dir })
    if type(result) == "boolean" then result = { exit_code = result and 0 or 1 } end
    return result or { exit_code = 1, stderr = "process runner returned no result" }
  end
  local function detail(result)
    local value = result and (result.stderr ~= "" and result.stderr or result.stdout) or nil
    return value and value ~= "" and (": " .. value) or ""
  end
  local function rollback_manifest()
    if initialized then
      os.remove(manifest_path)
    elseif original_manifest then
      write_file(manifest_path, original_manifest)
    end
  end

  if initialized then
    local result = invoke({ "init", ".", "--name", project_name, "--kind", "script",
      "--interpreter", "luajit@2.1", "--empty", "--no-git", "--no-sync", "--yes" })
    if result.exit_code ~= 0 then
      return nil, "Could not initialize this LÖVE game as a Moonstone project" .. detail(result)
    end
  end

  local exported = invoke({ "manifest", "export", "--json" })
  if exported.exit_code ~= 0 then
    rollback_manifest()
    return nil, "Could not inspect moonstone.toml" .. detail(exported)
  end
  local manifest, manifest_err = manifest_from_export(exported.stdout)
  if not manifest then
    rollback_manifest()
    return nil, "Could not read Moonstone's manifest contract: " .. manifest_err
  end
  local runtime = manifest.runtime or {}
  if not love_compatible_abi(runtime.abi) then
    rollback_manifest()
    return nil, string.format(
      "This project uses Lua ABI %s, but LÖVE 11.5 embeds LuaJIT/Lua 5.1. "
        .. "Choose the migration explicitly with `moon interpreter set luajit@2.1`, then rerun --add-love.",
      tostring(runtime.abi or "unknown")
    )
  end

  local dependencies, scripts = {}, {}
  for _, dependency in ipairs(manifest.dependencies or {}) do dependencies[dependency.name] = dependency.role end
  for _, script in ipairs(manifest.scripts or {}) do scripts[script.name] = script.command end

  local runtime_packages = {}
  if dependencies["hydronium/core"] ~= "runtime" then runtime_packages[#runtime_packages + 1] = "hydronium/core" end
  if #runtime_packages > 0 then
    local args = { "add", "--role", "runtime", "--no-sync" }
    for _, package_name in ipairs(runtime_packages) do args[#args + 1] = package_name end
    local result = invoke(args)
    if result.exit_code ~= 0 then rollback_manifest(); return nil, "Could not add Hydronium" .. detail(result) end
  end
  if dependencies["moonstone/ballad"] ~= "tool" then
    local result = invoke({ "add", "--tool", "--no-sync", "moonstone/ballad" })
    if result.exit_code ~= 0 then rollback_manifest(); return nil, "Could not add Ballad for dependency-closed packaging" .. detail(result) end
  end

  local desired_scripts = {
    ["love-dev"] = "love .",
    ["love-package"] = "moon exec -- ballad play hydronium.love.partiture.lua",
  }
  for _, name in ipairs({ "love-dev", "love-package" }) do
    if scripts[name] and scripts[name] ~= desired_scripts[name] then
      rollback_manifest()
      return nil, "Refusing to replace existing Moonstone script " .. name
    end
    if not scripts[name] then
      local result = invoke({ "manifest", "script", "set", name, "--command", desired_scripts[name] })
      if result.exit_code ~= 0 then rollback_manifest(); return nil, "Could not install Moonstone script " .. name .. detail(result) end
    end
  end

  local write_project = opts.write_project or writer.write_project
  local results, err = write_project(target_dir, files, {
    no_overwrite = true,
    cleanup_on_error = true,
  })
  if not results then rollback_manifest(); return nil, err end

  local synced = invoke({ "sync" })
  if synced.exit_code ~= 0 then
    return nil, "Hydronium was added, but Moonstone could not finish synchronization" .. detail(synced)
      .. ". The project is in a coherent pending state; rerun `moon sync`."
  end
  return {
    project_name = project_name,
    target_dir = target_dir,
    template = "love-addon",
    created = results.created,
    next_script = "love-dev",
    package_script = "love-package",
    dry_run = false,
    additive = true,
    synced = true,
  }
end

function create.scaffold(opts, ctx)
  opts = opts or {}
  local template_id = opts.template or "ssr"

  -- `spa` stays a known template key (templates/spa.lua still loads
  -- cleanly) but is deliberately unreachable through the normal
  -- unknown-template path below -- see that file's own header comment
  -- for exactly what's missing in the framework. Passing it directly
  -- must fail loudly with an explanation, not silently generate broken
  -- output (the bug this whole template set was audited for).
  if template_id == "spa" then
    return nil, "Template 'spa' is not yet supported -- hydronium has client mounting, bundling, and routing, "
      .. "but no complete server-less build and delivery recipe. "
      .. "Use 'ssr', 'islands', 'minimal', or 'ink'."
  end

  local template_spec = template_specs[template_id]
  if not template_spec then
    return nil, string.format("Unknown template '%s'. Available templates: %s", template_id, table.concat(template_order, ", "))
  end

  local interpreter = opts.interpreter or template_spec.default_interpreter or "luajit@2.1"
  if template_spec.interpreters then
    local allowed = false
    for _, candidate in ipairs(template_spec.interpreters) do
      if interpreter == candidate then allowed = true break end
    end
    if not allowed then
      return nil, string.format(
        "Template '%s' requires one of: %s. %s.",
        template_id,
        table.concat(template_spec.interpreters, ", "),
        template_spec.runtime_reason or "The selected host requires this runtime"
      )
    end
  end

  local target_dir = opts.directory or "."
  local project_name = opts.name
  if not project_name or project_name == "" then
    if target_dir == "." or target_dir == "./" then
      local handle = io.popen("basename \"$(pwd)\"")
      if handle then
        project_name = handle:read("*l")
        handle:close()
      end
    else
      project_name = target_dir:match("([^/]+)/?$") or "my-hydronium-app"
    end
  end
  project_name = project_name or "my-hydronium-app"

  -- Check if directory exists and is non-empty. Without a `ctx` (the
  -- programmatic path -- e.g. tests, or a future non-CLI caller) there
  -- is nobody to prompt, so the safe default is to REFUSE, the same way
  -- `--force` is required non-interactively -- not silently proceed and
  -- overwrite, which is what this used to do (the only path the test
  -- suite exercised was this one, which is exactly how it went
  -- unnoticed).
  if not opts.dry_run and not opts.force then
    if not is_directory_empty(target_dir) then
      if ctx and ctx.confirm then
        local confirmed = ctx:confirm(string.format("Directory '%s' is not empty. Continue anyway?", target_dir), { default = false })
        if not confirmed then
          return nil, "cancelled"
        end
      else
        return nil, string.format("Directory '%s' is not empty. Pass force = true to overwrite.", target_dir)
      end
    end
  end

  local files = template_spec.module.files({
    name = project_name,
    interpreter = interpreter,
  })

  local results, err = writer.write_project(target_dir, files, {
    dry_run = opts.dry_run,
  })
  if not results then
    return nil, err
  end

  -- Configure LuaLS with Alter
  local luals_res, luals_err = luals.configure(target_dir, {
    interpreter = interpreter,
    dry_run = opts.dry_run,
    luax = template_spec.tooling.luax,
    dom = template_spec.tooling.dom,
    bare_dom = template_spec.tooling.bare_dom,
    meteorite = template_spec.tooling.meteorite,
  })
  if not luals_res then
    return nil, string.format("Scaffolding succeeded but LuaLS configuration failed: %s", tostring(luals_err))
  end

  -- The generated .luarc.json is part of what --dry-run promises to
  -- report ("output generated file paths without writing files") -- it
  -- was previously invisible in both dry-run and real output because
  -- nothing appended it to `results.created`.
  table.insert(results.created, {
    path = ".luarc.json",
    full_path = luals_res.config_path,
    size = 0,
    via_luals = true,
  })

  return {
    project_name = project_name,
    target_dir = target_dir,
    template = template_id,
    created = results.created,
    luals = luals_res,
    next_script = template_spec.next_script,
    dry_run = opts.dry_run,
  }
end

return create
