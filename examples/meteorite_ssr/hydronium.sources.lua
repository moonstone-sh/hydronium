-- Project-owned source topology, consumed by hydronium_dom.dev.source_registry.
--
-- This is the selector that decides which files are hydronium app source, what
-- module id each one answers to, and how it is transformed. Declaring a root
-- with `transforms = { lua = "lua", luax = "luax" }` is what makes a plain
-- `.lua` component get the same treatment as a `.luax` one: the dev module
-- route serves it through hydronium_luax.loader, whose compile runs
-- hydronium_luax.transforms.refresh and generates the refresh descriptors that
-- let signal values survive a hot swap. Nothing here is `.luax`-specific.
--
-- Only the dual-HMR island is declared. This example's other demos
-- (hmr_demo/*, views/App.luax, src/views/App.lua) predate the topology and are
-- still served by their own bespoke routes; they are passed to
-- `registry:watch_files(extra)` so the watch set is unchanged, but they are
-- deliberately NOT given module ids here -- adding them would mean rewriting
-- those routes too, which is separate work.
return {
  entry = "dual_hmr.app",
  files = {
    "dual_hmr/app.lua",
  },
  roots = {
    {
      path = "dual_hmr",
      namespace = "dual_hmr",
      target = "client",
      update = "hot",
      effects = "safe",
      transforms = { lua = "lua", luax = "luax" },
    },
  },
}
