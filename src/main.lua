package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local c = require("clingy")
local v = require("valua")
local create = require("create.init")

local app
app = c.create({
  name = "hydronium-create",
  version = "0.1.0",
  description = "Scaffold and initialize new Hydronium reactive Lua projects",

  c.root(c.node({
    c.inherit(
      c.flag("-h", "--help"),
      c.flag("-v", "--version")
    ),

    c.optional(c.arg("directory", v.string())),
    c.complete(c.values("ssr", "islands", "spa", "minimal"), c.option("-t", "--template", v.string())),
    c.option("-n", "--name", v.string()),
    c.option("-i", "--interpreter", v.string()),
    c.flag("-f", "--force"),
    c.flag("--dry-run"),

    c.run(function(ctx)
      if ctx.args.version then
        ctx:log("info", "hydronium-create v0.1.0")
        return 0
      end

      if ctx.args.help then
        io.stdout:write(app:help() .. "\n")
        return 0
      end

      local target_dir = ctx.args.directory or "."
      local template_id = ctx.args.template or "ssr"

      ctx:log("info", string.format("Scaffolding Hydronium project in '%s' using template '%s'...", target_dir, template_id))

      local result, err = create.scaffold({
        directory = target_dir,
        template = template_id,
        name = ctx.args.name,
        interpreter = ctx.args.interpreter,
        force = ctx.args.force,
        dry_run = ctx.args["dry-run"],
      }, ctx)

      if not result then
        if err == "cancelled" then
          ctx:log("warn", "Operation cancelled.")
          return 0
        end
        ctx:log("error", tostring(err))
        return 1
      end

      -- Render creation summary
      io.stdout:write("\n")
      if result.dry_run then
        io.stdout:write(" [DRY RUN] The following files would be created:\n")
      else
        io.stdout:write(string.format(" ✓ Initialized '%s' (%s)\n", result.project_name, result.template))
      end

      for _, f in ipairs(result.created) do
        io.stdout:write(string.format("   + %s (%d bytes)\n", f.path, f.size))
      end

      io.stdout:write("\nNext steps:\n")
      if result.target_dir ~= "." and result.target_dir ~= "./" then
        io.stdout:write(string.format("  cd %s\n", result.target_dir))
      end
      io.stdout:write("  moon sync\n")
      io.stdout:write("  moon run dev\n\n")

      return 0
    end),
  })),
})

local exit_code = app:run(arg)
os.exit(exit_code or 0)
