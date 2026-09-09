package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local c = require("clingy")
local v = require("valua")
local create = require("create.init")

local app
app = c.create({
  name = "hydronium-create",
  version = "0.3.0",
  description = "Scaffold and initialize new Hydronium reactive Lua projects",

  c.root(c.node({
    c.inherit({
      c.flag({ key = "help", aliases = { "-h", "--help" } }),
      c.flag({ key = "version", aliases = { "-v", "--version" } }),
    }),

    c.arg({ key = "directory", schema = v.string(), occurs = { min = 0, max = 1 }, complete = c.directory() }),
    c.option({ key = "template", aliases = { "-t", "--template" }, value = { schema = v.string() }, complete = c.values(create.template_ids()) }),
    c.option({ key = "name", aliases = { "-n", "--name" }, value = { schema = v.string() } }),
    c.option({ key = "interpreter", aliases = { "-i", "--interpreter" }, value = { schema = v.string() }, complete = c.values({ "luajit@2.1", "lua@5.4" }) }),
    c.flag({ key = "minimal", aliases = { "--minimal" } }),
    c.flag({ key = "force", aliases = { "-f", "--force" } }),
    c.flag({ key = "dry_run", aliases = { "--dry-run" } }),

    c.run(function(ctx)
      if ctx.args.version then
        ctx:log("info", "hydronium-create v0.3.0")
        return 0
      end

      if ctx.args.help then
        io.stdout:write(app:help() .. "\n")
        return 0
      end

      local target_dir = ctx.args.directory or "."
      if ctx.args.minimal and ctx.args.template then
        ctx:fail("--minimal cannot be combined with --template", 1)
        return
      end
      if ctx.args.template == "minimal" then
        ctx:fail("minimal is selected with --minimal, not --template minimal", 1)
        return
      end
      local template_id = ctx.args.minimal and "minimal" or ctx.args.template or "ssr"

      ctx:log("info", string.format("Scaffolding Hydronium project in '%s' using template '%s'...", target_dir, template_id))

      local result, err = create.scaffold({
        directory = target_dir,
        template = template_id,
        name = ctx.args.name,
        interpreter = ctx.args.interpreter,
        force = ctx.args.force,
        dry_run = ctx.args.dry_run,
      }, ctx)

      if not result then
        if err == "cancelled" then
          ctx:log("warn", "Operation cancelled.")
          return 0
        end
        ctx:fail(tostring(err), 1)
        return
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
      io.stdout:write("  moon run " .. result.next_script .. "\n\n")

      return 0
    end),
  })),
})

local exit_code = app:run(arg)
os.exit(exit_code or 0)
