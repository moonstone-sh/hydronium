local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

local c = require("clingy")
local v = require("valua")
local runner = require("hydronium_lab_cli.runner")

local function common_options(run)
  return {
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
        adapter = ctx.args.adapter, no_open = ctx.args.no_open or ctx.args.ci, dry_run = ctx.args.dry_run })
      if not result then ctx:fail(tostring(err), 1); return end
      if ctx.args.dry_run then
        io.stdout:write(string.format("adapter: %s\nurl: %s\ncommand: %s\nstories: %d\n",
          result.adapter, result.url or "host-managed", result.command, #result.paths))
      end
      return 0
    end), { description = "Run the Lab workbench" }),
    init = c.node({
      c.run(function(ctx)
        if ctx.args.help then io.stdout:write(app:help() .. "\n"); return 0 end
        if ctx.args.version then io.stdout:write("hydronium-lab 0.1.0\n"); return 0 end
        local commands = {
          "moon add --dev --no-sync hydronium/lab hydronium/ink-lab hydronium/meteorite",
          "moon add --tool --no-sync hydronium/lab-cli moonstone/meteorite",
          "moon manifest script set lab --command 'moon exec --dev -- hydronium-lab dev'",
          "moon sync",
        }
        for _, command in ipairs(commands) do
          local ok, _, code = os.execute(command)
          if not (ok == true or ok == 0) then ctx:fail("command failed: " .. command .. " (" .. tostring(code or ok) .. ")", 1); return end
        end
        io.stdout:write("Hydronium Lab added. Create a *.stories.lua or *.stories.luax file, then run `moon run lab`.\n")
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
