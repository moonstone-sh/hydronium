/*
  A real `d.js.island` module, hydrating a server-rendered <button> with
  vanilla JS -- no framework, no build step, and (this is the point) no
  Lua or WASM anywhere in this file or its import graph. See
  ../../src/hydronium/client/bootstrap.js for the ABI this implements
  (context.root / context.props, hydrate/mount/dispose) and
  ../../docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md for what this proves.

  "hydrate" here means: claim the existing SSR button, don't replace it.
*/

const state = new WeakMap();

export function hydrate(context) {
  const button = context.root;
  const initial = context.props.initial ?? 0;
  let count = initial;

  const onClick = () => {
    count += 1;
    button.textContent = `Count: ${count}`;
  };
  button.addEventListener("click", onClick);
  state.set(button, { onClick, get: () => count });
}

export function dispose(context) {
  const button = context.root;
  const entry = state.get(button);
  if (!entry) return;
  button.removeEventListener("click", entry.onClick);
  state.delete(button);
}
