local writer = require("create.writer")
local luals = require("create.luals")

local templates = {
  ssr = require("create.templates.ssr"),
  islands = require("create.templates.islands"),
  spa = require("create.templates.spa"),
  minimal = require("create.templates.minimal"),
}

local create = {}

local template_tooling = {
  ssr = { luax = true, dom = true, bare_dom = true },
  islands = { luax = true, dom = true, bare_dom = true },
  minimal = { luax = false, dom = true, bare_dom = false },
}

-- `spa` is intentionally excluded here (and from src/main.lua's
-- `--template` completion list) -- see templates/spa.lua's own header
-- comment for why: nothing it promises (h.mount, a client bundler, a
-- `hydronium` CLI binary) exists in the framework today, and the file is
-- kept on disk (disabled) rather than deleted so the reasoning and the
-- real prerequisites for bringing it back stay attached to the code.
function create.available_templates()
  return {
    { id = "ssr", name = "SSR (Hydronium + Meteorite)", description = "Full-stack server-side rendered application with reactive views" },
    { id = "islands", name = "Islands Architecture", description = "Server-rendered shell with a real, client-hydrated JS island" },
    { id = "minimal", name = "Minimal Component", description = "Barebones reactive component for embedding or scripting" },
  }
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
    return nil, "Template 'spa' is not yet supported -- hydronium has no client-side SPA runtime yet. Use 'ssr', 'islands', or 'minimal'."
  end

  local template_mod = templates[template_id]
  if not template_mod then
    return nil, string.format("Unknown template '%s'. Available templates: ssr, islands, minimal", template_id)
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

  local files = template_mod.files({
    name = project_name,
    interpreter = opts.interpreter or "luajit@2.1",
  })

  local results, err = writer.write_project(target_dir, files, {
    dry_run = opts.dry_run,
  })
  if not results then
    return nil, err
  end

  -- Configure LuaLS with Alter
  local luals_res, luals_err = luals.configure(target_dir, {
    interpreter = opts.interpreter,
    dry_run = opts.dry_run,
    luax = template_tooling[template_id].luax,
    dom = template_tooling[template_id].dom,
    bare_dom = template_tooling[template_id].bare_dom,
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
    dry_run = opts.dry_run,
  }
end

return create
