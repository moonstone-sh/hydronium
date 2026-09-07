local writer = require("create.writer")

local templates = {
  ssr = require("create.templates.ssr"),
  islands = require("create.templates.islands"),
  spa = require("create.templates.spa"),
  minimal = require("create.templates.minimal"),
}

local create = {}

function create.available_templates()
  return {
    { id = "ssr", name = "SSR (Hydronium + Meteorite)", description = "Full-stack server-side rendered application with reactive views" },
    { id = "islands", name = "Islands Architecture", description = "Server-rendered shell with interactive client-side hydration islands" },
    { id = "spa", name = "Single Page App (SPA)", description = "Pure client-side reactive application" },
    { id = "minimal", name = "Minimal Component", description = "Barebones reactive component for embedding or scripting" },
  }
end

local function is_directory_empty(dir)
  local handle = io.popen(string.format('ls -A "%s" 2>/dev/null', dir))
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
  local template_mod = templates[template_id]
  if not template_mod then
    return nil, string.format("Unknown template '%s'. Available templates: ssr, islands, spa, minimal", template_id)
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

  -- Check if directory exists and is non-empty
  if not opts.dry_run and not opts.force then
    if not is_directory_empty(target_dir) then
      if ctx and ctx.prompt then
        local confirmed = ctx:confirm(string.format("Directory '%s' is not empty. Continue anyway?", target_dir), { default = false })
        if not confirmed then
          return nil, "cancelled"
        end
      end
    end
  end

  local files = template_mod.files({
    name = project_name,
    interpreter = opts.interpreter or "lua@5.4",
  })

  local results, err = writer.write_project(target_dir, files, {
    dry_run = opts.dry_run,
  })
  if not results then
    return nil, err
  end

  return {
    project_name = project_name,
    target_dir = target_dir,
    template = template_id,
    created = results.created,
    dry_run = opts.dry_run,
  }
end

return create
