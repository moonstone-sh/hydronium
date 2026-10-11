import { existsSync, readdirSync, readFileSync, mkdirSync, writeFileSync, realpathSync, renameSync } from 'node:fs';
import { resolve, relative, dirname } from 'node:path';
import { createHash } from 'node:crypto';

export interface LuaStylesOptions {
  /** Directories containing literal css.import("project/path.css") calls. */
  sources?: string[];
  /** Additional entries for dynamic declarations or a different local alias. */
  entries?: string[];
  /** Development class map read by the Lua asset provider. */
  modulesFile?: string;
}

/** Lua declares dependencies; Vite owns CSS parsing, modules, URLs and HMR. */
export function luaStyles(options: LuaStylesOptions = {}): any {
  let root = process.cwd();
  let building = false;
  let entries: string[] = [];
  const classes: Record<string, Record<string, string>> = {};
  const key = (filename: string) => relative(realpathSync(root), existsSync(filename) ? realpathSync(filename) : filename).replaceAll('\\', '/');
  const discover = (directory: string, found: Set<string>) => {
    if (!existsSync(directory)) return;
    for (const item of readdirSync(directory, { withFileTypes: true })) {
      const path = resolve(directory, item.name);
      if (item.isDirectory()) discover(path, found);
      else if (item.isFile() && /\.(lua|luax)$/.test(item.name)) {
        // Tokenize enough Lua to ignore comments and quoted examples. The
        // supported declaration is deliberately a literal css.import(path).
        const tokens = readFileSync(path, 'utf8').match(/--\[(=*)\[[\s\S]*?\]\1\]|--[^\n]*|\[(=*)\[[\s\S]*?\]\2\]|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_][A-Za-z_0-9]*|[^\s]/g) ?? [];
        const code = tokens.filter(token => !token.startsWith('--'));
        for (let i = 0; i + 5 < code.length; i++) {
          if (code[i] !== 'css' || code[i+1] !== '.' || code[i+2] !== 'import' || code[i+3] !== '(' || code[i+5] !== ')') continue;
          const literal = code[i+4].match(/^["']([^"'\\]+\.css)["']$/);
          if (literal) found.add(literal[1]);
        }
      }
    }
  };
  const collectEntries = () => {
    const found = new Set<string>(options.entries ?? []);
    for (const directory of options.sources ?? ['src', 'stories']) discover(resolve(root, directory), found);
    return [...found].sort();
  };
  const publish = () => {
    const file = resolve(root, options.modulesFile ?? '.hydronium/css-modules.json');
    mkdirSync(dirname(file), { recursive: true });
    const json = JSON.stringify(classes, null, 2) + '\n';
    if (!existsSync(file) || readFileSync(file, 'utf8') !== json) {
      writeFileSync(file + '.tmp', json);
      renameSync(file + '.tmp', file);
    }
  };
  return {
    name: 'hydronium-lua-styles',
    config(config: any, environment: any) {
      root = resolve(config.root ?? process.cwd());
      building = environment.command === 'build';
      entries = collectEntries();
      for (const name of Object.keys(classes)) delete classes[name];
      if (entries.some(entry => entry.endsWith('.module.css')) && config.css?.transformer === 'lightningcss') {
        throw Error('luaStyles CSS Modules currently requires Vite’s postcss transformer');
      }
      for (const entry of entries) {
        if (!existsSync(resolve(root, entry))) throw Error(`Lua stylesheet import does not exist: ${entry}`);
      }
      const input = config.build?.rollupOptions?.input;
      const merged: Record<string, string> = typeof input === 'string' ? {[input]: input}
        : Array.isArray(input) ? Object.fromEntries(input.map((p: string) => [p, p])) : {...input};
      if (!Object.keys(merged).length && existsSync(resolve(root, 'index.html'))) merged.index = 'index.html';
      for (const entry of entries) merged[entry] = entry;
      const previous = config.css?.modules?.getJSON;
      return {
        css: {modules: {generateScopedName: config.css?.modules?.generateScopedName ?? ((name: string, filename: string) => {
          // Content-independent names preserve Lua state during CSS HMR.
          const hash = createHash('sha256').update(key(filename)).update('\0').update(name).digest('hex').slice(0, 12);
          return `h_${name}_${hash}`;
        }), getJSON(filename: string, mapping: Record<string, string>, output: string) {
          classes[key(filename)] = mapping;
          if (!building) publish();
          return previous?.(filename, mapping, output);
        }}},
        build: {manifest: true, ...(Object.keys(merged).length ? {rollupOptions: {input: merged}} : {})},
      };
    },
    async configureServer(server: any) {
      for (const entry of entries) if (entry.endsWith('.module.css')) await server.transformRequest('/' + entry);
      publish();
      const updateImports = async (file: string) => {
        if (!/\.(lua|luax)$/.test(file)) return;
        try {
          if (JSON.stringify(collectEntries()) !== JSON.stringify(entries)) await server.restart();
        } catch (error) {
          server.config.logger.error(String(error));
        }
      };
      for (const event of ['add', 'change', 'unlink']) server.watcher.on(event, updateImports);
    },
    async handleHotUpdate(context: any) {
      // Composition dependencies may be ordinary .css files.
      if (!context.file.endsWith('.css')) return;
      const previousClasses = JSON.stringify(classes);
      // Class names and composition can change even when Lua source does not.
      // Refresh exports before reloading; never leave old classes on live DOM.
      for (const module of context.modules) context.server.moduleGraph.invalidateModule(module);
      for (const entry of entries) {
        if (!entry.endsWith('.module.css')) continue;
        const module = await context.server.moduleGraph.getModuleByUrl('/' + entry);
        if (module) context.server.moduleGraph.invalidateModule(module);
        await context.server.transformRequest('/' + entry);
      }
      publish();
      if (JSON.stringify(classes) !== previousClasses) {
        context.server.ws.send({type: 'full-reload'});
        return [];
      }
      // Lua subscribes through <link>, not a JS import. Direct CSS Modules
      // have no accepting JS boundary; send Vite's link-update protocol and
      // exclude them from propagation so it cannot fall back to a reload.
      const linked = context.modules.filter((module: any) => module.type === 'css');
      if (linked.length) context.server.ws.send({type: 'update', updates: linked.map((module: any) => ({
        type: 'css-update', path: module.url, acceptedPath: module.url, timestamp: context.timestamp,
      }))});
      // configureServer prewarms the JS representation to obtain exports.
      // If Lua subscribes with a stylesheet link, that orphan JS module has
      // no accepting importer and would make Vite reload the whole page.
      return context.modules.filter((module: any) => module.type !== 'css'
        && (module.isSelfAccepting || module.importers?.size > 0));
    },
    generateBundle: {
      order: 'post',
      handler(_options: any, bundle: any) {
        const file = bundle['.vite/manifest.json'];
        if (!file || typeof file.source !== 'string') return;
        const manifest = JSON.parse(file.source);
        for (const [entry, mapping] of Object.entries(classes)) {
          if (manifest[entry]) manifest[entry].classes = mapping;
        }
        file.source = JSON.stringify(manifest, null, 2);
      },
    },
  };
}
