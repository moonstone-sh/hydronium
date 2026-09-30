-- scripts/lua-hot-update.mjs for Vite-based templates. Lua source discovery
-- is Ballad's job (partiture.lua, kept current by `hydronium dev
-- --watch-sources`); this plugin only keeps Vite from reacting to Lua edits
-- with a full-page reload, which would destroy the browser Lua VM that
-- Hydronium's own HMR is preserving.
return [=[
export function hydroniumLuaHotUpdate() {
  return {
    name: 'hydronium-lua-hot-update',
    // Lua edits are owned by Hydronium. Tailwind registers them as asset
    // dependencies and otherwise requests a full-page reload. Give Vite
    // only their CSS importers so it can update styles without losing Lua state.
    hotUpdate: {
      order: 'pre',
      handler({ file, modules }) {
        if (!/\.(lua|luax)$/.test(file)) return;
        const seen = new Set();
        const css = new Set();
        const visit = module => {
          if (seen.has(module)) return;
          seen.add(module);
          if (module.type === 'css') css.add(module);
          else for (const importer of module.importers) visit(importer);
        };
        for (const module of modules) visit(module);
        return [...css];
      },
    },
  };
}
]=]
