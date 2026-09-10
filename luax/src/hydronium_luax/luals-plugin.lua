--[[
  hydronium-luax — LuaLS plugin self-description.

  Read by `moonstone/luals-composer` when a consuming project enrolls this
  package by name:

      require("luals_composer").enroll{
        root   = project_root,
        plugin = { name = "hydronium-luax", priority = "first" },
      }

  Composer loads this file as inert data in an empty environment, so it must
  contain nothing but this table.

  Composer looks for it at the root of this package's INSTALLED Lua module tree
  (`.moonstone/env/share/lua/<abi>/hydronium_luax/luals-plugin.lua`) — the
  package name's `-` becomes `_` there, as Moonstone already does. `path` is
  relative to this file.

  ORDERING IS NOT DECLARED HERE, deliberately. `.luax` files are the one case
  in this workspace where a plugin owns whole regions and must win a genuine
  range conflict, so hydronium-luax wants to sit FIRST in a consumer's
  registry. But priority is a property of the consuming workspace, not of a
  package — Composer ignores a `priority` field in a manifest so that no
  package can promote itself above its neighbours in someone else's project.
  A consumer asks for it explicitly, as shown above.
--]]

return {
  name = "hydronium-luax",

  -- The OnSetText + ResolveRequire plugin proper: projects `.luax` into
  -- byte-aligned virtual Lua. `.luax` is not valid Lua, so without this LuaLS
  -- does not mistype the file, it fails to parse it.
  path = "luals/init.lua",

  -- Verified against luals-composer 0.1.0 (2026-09-10), 2- and 3-plugin
  -- composition against a real headless lua-language-server 3.18.2-dev.
  transport = "^0.1.0",
  contract = 1,

  -- `ranges`, NOT `insertions`, and this is the only plugin here that needs
  -- it: `OnSetText` returns `compute_diff(text, virtual_code)`, which REPLACES
  -- each JSX span with lowered Lua, so its hunks are not zero-width.
  --
  -- It must still never return a whole-document hunk. The `if #diffs == 0 then
  -- diffs = {{ start = 1, finish = #text, text = virtual_code }} end` fallback
  -- that used to do exactly that on a JSX-free `.luax` file was deleted on
  -- 2026-09-10; a JSX-free file now correctly yields zero hunks. Composer's
  -- `contract.check_edits` rejects a whole-document hunk outright as a second
  -- line of defence.
  text_edits = "ranges",

  args = {},
}
