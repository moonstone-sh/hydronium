import { hydrate, dispose } from "./counter-island.js";
import "./styles.css";

// Set exactly once per real page load: this module's top-level body runs
// once at initial script evaluation and never again unless the whole page
// reloads -- Vite HMR re-executes only accepted modules, not their
// importers' top-level state. The M1 Playwright gate reads this before and
// after an HMR-patched edit to counter-island.js and asserts it is
// UNCHANGED -- that's the assertion that distinguishes a real HMR patch
// from Vite falling back to a full page reload.
window.__bootId = crypto.randomUUID();

const root = document.getElementById("app-root");
let ctx = { root, props: { initial: 0 } };

hydrate(ctx);

if (import.meta.hot) {
  import.meta.hot.accept("./counter-island.js", (mod) => {
    if (!mod) return; // module removed entirely; nothing sane to do here
    dispose(ctx);
    ctx = { root, props: { initial: 0 } };
    mod.hydrate(ctx);
  });
}
