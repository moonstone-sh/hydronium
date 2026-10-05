#!/usr/bin/env bash
# HYDRONIUM_CONSUMER_PREPARE step for the React island gate: turns the islands
# scaffold's plain-JS counter into a React component, the way a user would --
# add react/react-dom and @vitejs/plugin-react, write a .jsx island, point the
# page at it. Everything else (registry, sync, Vite build, Meteorite build,
# serving) is the unchanged consumer gate. Runs inside the scaffolded app.
set -euo pipefail

[[ -f vite.config.js && -f src/views/Home.luax && -f src/islands/counter.js ]] \
  || { echo "react island prepare: expected an islands scaffold with a Vite island" >&2; exit 1; }

bun add react@19 react-dom@19
bun add -d @vitejs/plugin-react

# The island: server-rendered markup is hydrated by React (hydrateRoot), so
# the first client render must produce the same HTML as the SSR output --
# one text node "Count: N", same attributes. `data-react-island` is set only
# after React commits, so the browser gate can tell hydration really ran.
cat > src/islands/counter.jsx <<'JSX'
import { useEffect, useState, version } from "react";
import { hydrateRoot } from "react-dom/client";

// Same markup as the server-rendered group in src/views/Home.luax.
function Counter({ initial }) {
  const [times, setTimes] = useState(initial);
  useEffect(() => { document.documentElement.dataset.reactIsland = version; }, []);
  return (
    <span className="counter" role="group" aria-label="Times" data-testid="js-counter">
      <button type="button" aria-label="Fewer" disabled={times <= 1} onClick={() => setTimes((n) => n - 1)}>−</button>
      <output className="count">{String(times)}</output>
      <button type="button" aria-label="More" disabled={times >= 9} onClick={() => setTimes((n) => n + 1)}>+</button>
      <input type="hidden" name="times" value={String(times)} />
    </span>
  );
}

const roots = new WeakMap();

export function hydrate(context) {
  roots.set(context.root, hydrateRoot(context.root, <Counter initial={context.props.times ?? 3} />));
}

export function dispose(context) {
  roots.get(context.root)?.unmount();
  roots.delete(context.root);
}
JSX
rm src/islands/counter.js

# React needs an element to hydrate *into*: wrap the island's root group in a
# <span>, which becomes `context.root` (the island still renders one root).
node - <<'NODE'
const fs = require("node:fs");
const edit = (path, from, to) => {
  const source = fs.readFileSync(path, "utf8");
  if (!source.includes(from)) throw new Error(`react island prepare: anchor not found in ${path}: ${from}`);
  fs.writeFileSync(path, source.replace(from, to));
};
edit("vite.config.js", 'import { hydronium } from "@hydronium-js/vite";',
  'import { hydronium } from "@hydronium-js/vite";\nimport react from "@vitejs/plugin-react";');
edit("vite.config.js", '"src/islands/counter.js"', '"src/islands/counter.jsx"');
edit("vite.config.js", "plugins: [", "plugins: [\n    react(),");
edit("src/views/Home.luax", 'module="src/islands/counter.js"', 'module="src/islands/counter.jsx"');
edit("src/views/Home.luax", 'return <d.span class="counter"', 'return <d.span data-react-root><d.span class="counter"');
edit("src/views/Home.luax", 'value={tostring(props.times)} /></d.span>', 'value={tostring(props.times)} /></d.span></d.span>');
NODE

echo "react island prepare: counter is now a React $(node -p 'require("react/package.json").version') island"
