// A real `d.js.island`-shaped module -- same hydrate/mount/dispose ABI as
// ../../../../../examples/js_island/counter.js (see
// dom/src/hydronium_dom/client/bootstrap.js for the ABI that implements:
// context.root / context.props, hydrate(context)/mount(context) +
// optional dispose(context)).
//
// Imports a real npm dependency (nanoid) so this proves a genuine
// package-manager-resolved module graph, not just static assets: its
// output (a per-hydrate session id) is visibly written into the DOM.
//
// "hydrate" here means: claim the existing markup, don't replace it --
// same meaning as in counter.js.
import { nanoid } from "nanoid";

const state = new WeakMap();

export function hydrate(context) {
  const button = context.root;
  const initial = context.props.initial ?? 0;
  let count = initial;
  const sessionId = nanoid(8);

  button.textContent = `Count: ${count}`;
  button.dataset.session = sessionId;

  const onClick = () => {
    count += 1;
    button.textContent = `Count: ${count}`;
  };
  button.addEventListener("click", onClick);
  state.set(button, { onClick });
}

export function dispose(context) {
  const button = context.root;
  const entry = state.get(button);
  if (!entry) return;
  button.removeEventListener("click", entry.onClick);
  state.delete(button);
}

// Deliberately NO `import.meta.hot.accept()` here. main.js is the acceptor
// (`import.meta.hot.accept("./counter-island.js", cb)`) -- an importer
// accepting updates on behalf of a non-self-accepting dependency is
// Vite's documented alternative to self-accepting, and keeping the accept
// call in main.js is what lets main.js control the dispose-old/hydrate-new
// sequence with the *new* module's exports.
