-- Derived from this script's own invocation path (arg[0]), not the
-- current working directory: a hardcoded "./src/..." prefix only ever
-- worked when CWD happened to be this package's own root (true for local
-- dev, via `lua src/main.lua`, but not once installed as a global tool
-- and invoked from wherever a user happens to be -- the actual reported
-- failure mode this masked, though the launcher script's own LUA_PATH
-- should now find these modules first regardless; this just stops the
-- fallback from being a footgun that could shadow the real files with an
-- unrelated "./src/..." in the invoking directory).
local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

local c = require("clingy")
local v = require("valua")
local create = require("create.init")
local wizard = require("create.wizard")
local pm = require("create.pm")
local wizard_tasks = require("create.wizard_tasks")

-- Shared by both the ordinary flag-driven path and the interactive wizard
-- path below -- the two differ only in how `opts` gets built; once
-- `create.scaffold`/`create.add_love` has actually run, reporting the
-- result back to the user is identical either way.
local function render_result(result)
  io.stdout:write("\n")
  if result.dry_run then
    io.stdout:write(" [DRY RUN] The following files would be created:\n")
  else
    io.stdout:write(string.format(" \226\156\147 Initialized '%s' (%s)\n", result.project_name, result.template))
  end

  for _, f in ipairs(result.created) do
    io.stdout:write(string.format("   + %s (%d bytes)\n", f.path, f.size))
  end

  if result.package_manager or result.router then
    io.stdout:write("\n")
    if result.package_manager then
      io.stdout:write(string.format("  Vite: enabled (%s%s)\n",
        result.tailwind and "Tailwind CSS v4 + " or "", result.package_manager))
      if #pm.detect() == 0 then
        io.stdout:write("    note: no package manager (npm, pnpm, or bun) found on PATH -- files are\n")
        io.stdout:write(string.format("    still created; install one to run %s\n", result.package_manager))
      end
    end
    if result.router then io.stdout:write(string.format("  Routing: %s\n", result.router)) end
  end

  io.stdout:write("\nNext steps:\n")
  if result.target_dir ~= "." and result.target_dir ~= "./" then
    io.stdout:write(string.format("  cd %s\n", result.target_dir))
  end
  if not result.synced then io.stdout:write("  moon sync\n") end
  io.stdout:write("  moon run " .. result.next_script .. "\n")
  -- Every Vite template (ssr/spa/islands), not only when Tailwind is on --
  -- Vite is the base now, Tailwind a purely additive layer on top of it
  -- (see create/vite.lua and create/tailwind.lua's own header comments).
  if result.package_manager and not result.dry_run and not result.js_installed then
    io.stdout:write(string.format("  %s && %s\n",
      pm.install_command(result.package_manager), pm.run_command(result.package_manager, "build")))
  end
  io.stdout:write("\n")
  if result.package_script then
    io.stdout:write("Package with:\n  moon run " .. result.package_script .. "\n\n")
  end

  return 0
end

local app
app = c.create({
  name = "hydronium-create",
  version = "0.5.0",
  description = "Scaffold and initialize new Hydronium reactive Lua projects",

  root = c.node({
    c.inherit({
      c.flag({ key = "help", aliases = { "-h", "--help" } }),
      c.flag({ key = "version", aliases = { "-v", "--version" } }),
    }),

    c.arg({ key = "directory", schema = v.string(), occurs = { min = 0, max = 1 }, complete = c.directory() }),
    c.option({ key = "template", aliases = { "-t", "--template" }, value = { schema = v.string() }, complete = c.values(create.template_ids()) }),
    c.option({ key = "name", aliases = { "-n", "--name" }, value = { schema = v.string() } }),
    c.option({ key = "interpreter", aliases = { "-i", "--interpreter" }, value = { schema = v.string() }, complete = c.values({ "luajit@2.1", "lua@5.4" }) }),
    c.flag({ key = "minimal", aliases = { "--minimal" } }),
    c.flag({ key = "add_love", aliases = { "--add-love" } }),
    c.flag({ key = "force", aliases = { "-f", "--force" } }),
    c.flag({ key = "dry_run", aliases = { "--dry-run" } }),
    c.flag({ key = "tailwind", aliases = { "--tailwind" } }),
    c.option({ key = "package_manager", aliases = { "--package-manager" }, value = { schema = v.string() }, complete = c.values(pm.candidates) }),
    c.option({ key = "router", aliases = { "--router" }, value = { schema = v.string() }, complete = c.values({ "hydronium", "meteorite" }) }),
    c.flag({ key = "yes", aliases = { "-y", "--yes" } }),
    c.flag({ key = "wizard", aliases = { "--wizard" } }),
    -- Mirrors the interactive wizard's own "install dependencies now"/
    -- "git init" toggles (create.ui.wizard_app) as flags for the
    -- non-interactive path -- see the post-scaffold block in `run` below,
    -- which uses the exact same create.wizard_tasks runner the wizard
    -- itself uses for real (never faked) work. Unlike the wizard, where
    -- both default ON, this flag-driven path defaults BOTH off (matching
    -- this CLI's long-standing behavior of only ever printing "next
    -- steps" unless told otherwise) -- explicit --no-install/--no-git
    -- exist purely so a combination like `--install --no-git` reads
    -- unambiguously, and so passing the wrong pair together fails loudly
    -- instead of picking one silently.
    c.flag({ key = "install", aliases = { "--install" } }),
    c.flag({ key = "no_install", aliases = { "--no-install" } }),
    c.flag({ key = "git", aliases = { "--git" } }),
    c.flag({ key = "no_git", aliases = { "--no-git" } }),

    c.run(function(ctx)
      if ctx.args.version then
        ctx:log("info", "hydronium-create v0.5.0")
        return 0
      end

      if ctx.args.help then
        io.stdout:write(app:help() .. "\n")
        return 0
      end

      -- Interactive wizard: only when nothing on argv already disambiguates
      -- what to scaffold, and only in a real terminal (`--wizard` requires
      -- one explicitly; ambient auto-trigger just skips quietly so scripts
      -- and CI fall through to the ordinary flag-driven path below, and
      -- non-TTY stdin can never hang on a prompt).
      if not ctx.args.add_love then
        local has_explicit_choice = ctx.args.template ~= nil or ctx.args.minimal or ctx.args.directory ~= nil
          or ctx.args.name ~= nil or ctx.args.yes
        local is_tty = wizard.detect_tty()
        if ctx.args.wizard and not is_tty then
          ctx:fail("--wizard requires an interactive terminal (stdin and stdout must both be a TTY)", 1)
          return
        end
        if ctx.args.wizard or (is_tty and not has_explicit_choice) then
          -- THE Ink component (create.ui.wizard_app) -- the exact same
          -- one `install-flow` exercises in Ink Lab (see
          -- create/src/create/ui/create.stories.lua and that module's own
          -- header comment: one component, two hosts, never two
          -- implementations). `hydronium_ink.render` blocks until the
          -- component calls `useApp().exit()` (the wizard's own "result"
          -- step, on any key) or Ctrl-C -- both leave `captured_result`
          -- nil if the wizard never reached (or aborted before) that step.
          local hydronium = require("hydronium")
          -- `render` lives in the hydronium_ink.render submodule, not
          -- re-exported from hydronium_ink's own init.lua (see that
          -- package's init.lua: it only exports Box/Text/Newline/etc,
          -- terminal_background, colorProfile/byProfile/adaptive -- never
          -- `render` itself). `ink.render(element)` here was a real bug
          -- that made `--wizard` (and the ambient auto-wizard) crash
          -- outright the moment either actually ran, with `attempt to
          -- call field 'render' (a nil value)` -- caught only by
          -- launching this CLI under a genuine pty and pressing keys
          -- (see hydronium/cli's own src/main.lua's `M.dev` for the same
          -- `require("hydronium_ink.render")` pattern this now matches).
          local ink_render = require("hydronium_ink.render")
          local wizard_app = require("create.ui.wizard_app")

          local captured_result, captured_err
          local element = hydronium.h(wizard_app.create_wizard_app({
            directory = ctx.args.directory,
            force = ctx.args.force,
            dry_run = ctx.args.dry_run,
            -- The H3O cue belongs only to the real interactive terminal.
            -- Lab, CI, and NO_COLOR all start directly on the persistent form.
            intro = os.getenv("CI") == nil and os.getenv("NO_COLOR") == nil,
            -- Reads a cached registry index; refreshes it in the background.
            check_updates = true,
            onDone = function(res, err) captured_result, captured_err = res, err end,
          }))
          ink_render.render(element)

          if not captured_result then
            if captured_err == nil or captured_err == "cancelled" then
              ctx:log("warn", "Cancelled. No files were written.")
              return 0
            end
            ctx:fail(tostring(captured_err), 1)
            return
          end
          return render_result(captured_result)
        end
      end

      if ctx.args.install and ctx.args.no_install then
        ctx:fail("--install cannot be combined with --no-install", 1)
        return
      end
      if ctx.args.git and ctx.args.no_git then
        ctx:fail("--git cannot be combined with --no-git", 1)
        return
      end

      local target_dir = ctx.args.directory or "."
      if ctx.args.minimal and ctx.args.template then
        ctx:fail("--minimal cannot be combined with --template", 1)
        return
      end
      if ctx.args.add_love and (ctx.args.minimal or ctx.args.template) then
        ctx:fail("--add-love cannot be combined with --minimal or --template", 1)
        return
      end
      if ctx.args.template == "minimal" then
        ctx:fail("minimal is selected with --minimal, not --template minimal", 1)
        return
      end
      local template_id = ctx.args.add_love and "love-addon" or ctx.args.minimal and "minimal" or ctx.args.template or "ssr"

      ctx:log("info", string.format("Scaffolding Hydronium project in '%s' using template '%s'...", target_dir, template_id))

      local action = ctx.args.add_love and create.add_love or create.scaffold
      local result, err = action({
        directory = target_dir,
        template = template_id,
        name = ctx.args.name,
        interpreter = ctx.args.interpreter,
        force = ctx.args.force,
        dry_run = ctx.args.dry_run,
        tailwind = ctx.args.tailwind,
        package_manager = ctx.args.package_manager,
        router = ctx.args.router,
      }, ctx)

      if not result then
        if err == "cancelled" then
          ctx:log("warn", "Operation cancelled.")
          return 0
        end
        ctx:fail(tostring(err), 1)
        return
      end

      -- The same real (never faked) task runner the interactive wizard's
      -- post-submit checklist uses (create.wizard_tasks) -- see the flags'
      -- own declaration above for why both default off here. `add_love`
      -- already runs its own `moon sync` unconditionally (see create.init's
      -- add_love, which reports `result.synced`), so `--install` only adds
      -- anything new for the ordinary `create.scaffold` path.
      if not result.dry_run and (ctx.args.install or ctx.args.git) and action == create.scaffold then
        local plan = wizard_tasks.plan({
          install_deps = ctx.args.install == true, vite = result.vite, git_init = ctx.args.git == true,
          package_manager = result.package_manager,
        })
        for _, task in ipairs(plan) do
          if task.id ~= "write" then
            local ok, task_err = wizard_tasks.run_task(task, { target_dir = result.target_dir, package_manager = result.package_manager, dry_run = false })
            if ok then
              ctx:log("info", task.label .. ": done")
              if task.id == "sync" then result.synced = true end
              if task.id == "js_install" then result.js_installed = true end
            else
              ctx:log("warn", task.label .. " failed: " .. tostring(task_err))
            end
          end
        end
      end

      return render_result(result)
    end),
  }),
})

local exit_code = app:run(arg)
os.exit(exit_code or 0)
