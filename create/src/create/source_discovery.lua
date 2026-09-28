return [=[
import { readdirSync, readFileSync, mkdirSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';

// Discovery runs in the tooling process, never inside an HTTP handler.
export function prepareSources() {
  const files = [];
  function scan(dir) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name).replaceAll('\\', '/');
      if (entry.isDirectory()) scan(path);
      else if (entry.isFile() && /\.(lua|luax)$/.test(path)) files.push(path);
    }
  }
  scan('src');
  files.sort();
  const quote = (s) => '"' + s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r') + '"';
  const code = 'local config = dofile("hydronium.sources.lua")\nconfig.files = {\n'
    + files.map(p => `  ${quote(p)},`).join('\n') + '\n}\nreturn config\n';
  const path = '.hydronium/sources.lua';
  mkdirSync('.hydronium', { recursive: true });
  let previous;
  try { previous = readFileSync(path, 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (previous !== code) {
    writeFileSync(path + '.tmp', code);
    renameSync(path + '.tmp', path);
  }
}

export function hydroniumSources() {
  return {
    name: 'hydronium-source-discovery',
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
    buildStart: prepareSources,
    configureServer(server) {
      prepareSources();
      const update = path => { if (/\.(lua|luax)$/.test(path) && !path.includes('/.hydronium/')) prepareSources(); };
      server.watcher.on('add', update).on('unlink', update);
      server.httpServer?.once('close', () => {
        server.watcher.off('add', update).off('unlink', update);
      });
    },
  };
}
]=]
