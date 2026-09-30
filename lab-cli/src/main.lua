local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

local c = require("clingy")
local v = require("valua")
local runner = require("hydronium_lab_cli.runner")

local function common_options(run)
  return {
    c.option({ key = "renderer", aliases = { "--renderer" }, value = { schema = v.string() }, complete = c.values({ "ink", "dom", "mixed" }) }),
    c.option({ key = "host", aliases = { "--host" }, value = { schema = v.string() } }),
    c.option({ key = "port", aliases = { "--port" }, value = { schema = v.integer() } }),
    c.option({ key = "config", aliases = { "--config" }, value = { schema = v.string() }, complete = c.file() }),
    c.option({ key = "adapter", aliases = { "--adapter" }, value = { schema = v.string() }, complete = c.values({ "meteorite" }) }),
    c.flag({ key = "no_open", aliases = { "--no-open" } }),
    c.flag({ key = "ci", aliases = { "--ci" } }),
    c.flag({ key = "dry_run", aliases = { "--dry-run" } }),
    c.run(run),
  }
end

local app
app = c.create({
  name = "hydronium-lab",
  version = "0.1.0",
  description = "Discover component stories and run them with an explicit Lab host adapter",
  root = c.node({
    c.inherit({
      c.flag({ key = "help", aliases = { "-h", "--help" } }),
      c.flag({ key = "version", aliases = { "-v", "--version" } }),
    }),
    dev = c.node(common_options(function(ctx)
      if ctx.args.help then io.stdout:write(app:help() .. "\n"); return 0 end
      if ctx.args.version then io.stdout:write("hydronium-lab 0.1.0\n"); return 0 end
      local port = ctx.args.port or 6100
      if port < 1 or port > 65535 then ctx:fail("--port must be from 1 to 65535", 1); return end
      local result, err = runner.run({ host = ctx.args.host or "127.0.0.1", port = port, config = ctx.args.config,
        renderer = ctx.args.renderer, adapter = ctx.args.adapter, no_open = ctx.args.no_open or ctx.args.ci, dry_run = ctx.args.dry_run })
      if not result then ctx:fail(tostring(err), 1); return end
      if ctx.args.dry_run then
        io.stdout:write(string.format("adapter: %s\nurl: %s\ncommand: %s\nstories: %d\n",
          result.adapter, result.url or "host-managed", result.command, #result.paths))
      end
      return 0
    end), { description = "Run the Lab workbench" }),
    customize = c.node({
      c.flag({ key = "copy_shell", aliases = { "--copy-shell" } }),
      c.flag({ key = "dry_run", aliases = { "--dry-run" } }),
      c.run(function(ctx)
        if ctx.args.help then io.stdout:write(app:help() .. "\n"); return 0 end
        local result, err = runner.customize({ copy_shell = ctx.args.copy_shell, dry_run = ctx.args.dry_run })
        if not result then ctx:fail(err, 1); return end
        io.stdout:write("Lab customization: .lab/Workbench.luax (run moon run lab after editing)\n")
        return 0
      end),
    }, { description = "Create an optional editable Lab entry; --copy-shell copies default markup" }),
    init = c.node({
      c.option({ key = "renderer", aliases = { "--renderer" }, value = { schema = v.string() }, complete = c.values({ "ink", "dom", "mixed" }) }),
      c.flag({ key = "dry_run", aliases = { "--dry-run" } }),
      c.run(function(ctx)
        if ctx.args.help then io.stdout:write(app:help() .. "\n"); return 0 end
        if ctx.args.version then io.stdout:write("hydronium-lab 0.1.0\n"); return 0 end
        local result, err = runner.initialize({ renderer = ctx.args.renderer, dry_run = ctx.args.dry_run })
        if not result then ctx:fail(err, 1); return end
        if ctx.args.dry_run then
          for _, command in ipairs(result.commands) do
            io.stdout:write(command .. "\n")
          end
          return 0
        end
        io.stdout:write("Hydronium Lab is ready. Create a *.stories.lua, *.stories.luax, *.stories.md, or *.stories.mdx file, then run `moon run lab`.\n")
        return 0
      end),
    }, { description = "Add Lab development and host dependencies to a project" }),
    c.run(function(ctx)
      if ctx.args.version then io.stdout:write("hydronium-lab 0.1.0\n"); return 0 end
      io.stdout:write(app:help() .. "\n")
      return ctx.args.help and 0 or 1
    end),
  }),
})

os.exit(app:run(arg) or 0)
