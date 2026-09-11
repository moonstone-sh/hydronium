--[[
  DISABLED: this template is intentionally NOT reachable through
  `create.scaffold`/`create.available_templates()` or the CLI's
  `--template` completion list -- see src/create/init.lua's
  `create.scaffold` (it returns a clear error for `--template spa`
  specifically) and src/main.lua's `c.complete(c.values(...))` list.

  ---------------------------------------------------------------------
  CORRECTION (2026-09-10). The 2026-09-07 version of this comment gave
  three reasons for the block. ALL THREE ARE NOW FALSE and have been
  retracted. They were, verbatim, and what is actually true today:

    * "There is no `h.mount(component, selector)` API anywhere."
      FALSE. `dom/src/hydronium_dom/client/mount.js` exports a real
      `mount(options)` whose `options.container` is exactly "a CSS
      selector or a real DOM element to mount/hydrate into".

    * "There is no real client bootstrap entry point that can run an
      actual Hydronium component tree in a browser from scratch (not
      just hydrating server-rendered islands)."
      FALSE. `mount()` takes `hydrate: false` (its default), which
      routes to `Reconciler:mount` and builds the DOM fresh rather than
      claiming SSR output. `templates/ssr.lua` (~L236-L261) already
      issues exactly that from-scratch mount call.

    * "There is no client-side bundler or dev-server story for `.luax`
      files served directly to a browser."
      FALSE on both halves. `hydronium_ballad.plugins.client` really
      resolves, amalgamates, minifies and splits app+framework Lua into
      `format = "package_preload_v1"` chunks (`M.bundle`, and
      `mount()`'s `chunkUrls` option consumes them); and a real
      on-demand `.luax` dev pipeline exists -- `templates/ssr.lua`
      generates routes serving `/hydronium-src`,
      `/__hydronium/client_manifest.json`, and
      `/__hydronium/dev/module/:id` (compiled per request).

  ---------------------------------------------------------------------
  WHY IT IS STILL BLOCKED, accurately, as of 2026-09-11:

  `moonstone/hydronium-router` now supplies route declarations, reactive
  Router/Outlet/hooks, and memory/browser History adapters. Its browser
  bridge composes through mount({ luaGlobals = ... }), so client-side
  view navigation is no longer the blocker.

  There is still no complete server-less delivery story, and no `hydronium` CLI to
     provide one. Every real client mount that exists today is served
     by a Meteorite app: the URLs `mount()` needs
     (`hydroniumBaseUrl`, `manifestUrl`, `appModuleUrl`, or bundled
     `chunkUrls`) are produced by generated Meteorite routes or by a
     Ballad partiture build. The root package is `kind = "script"`, not
     a `kind = "bin"` executable -- `hydronium dev` and
     `hydronium build` still do not exist. So a scaffolded `spa`
     project today would either ship a Meteorite server (making it the
     `ssr` template with `hydrate = false`, not a distinct template) or
     ship nothing runnable.

  What would need to be true before this template comes back for real:

    1. Either a `kind = "bin"` `hydronium` CLI with real `dev`/`build`
       subcommands, or a documented Ballad partiture recipe that emits
       a static directory (bundled `chunkUrls` + `index.html`) a plain
       static file server can host with no Meteorite process.

  Until then, `create.scaffold({template = "spa"})` returns a clear
  error instead of generating code that cannot run -- see
  src/create/init.lua. Do not restore this template on the strength of
  `mount()` and routing existing alone; both are necessary, but neither
  supplies the static output and development-server contract.
]]

local spa = {}

function spa.files(opts)
  error("The 'spa' template is disabled -- see the comment at the top of this file for why.", 2)
end

return spa
