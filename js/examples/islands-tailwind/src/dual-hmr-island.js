// A second, SELF-ACCEPTING JS island used only by the M2 dual-HMR
// coexistence proof (examples/meteorite_ssr's /dual-hmr route, per
// docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md). Deliberately separate from
// ./counter-island.js (M1, already gated and independently verified) --
// M2 loads THIS module directly via a real SSR page's bootstrap.js, a
// plain static script Meteorite serves that is NOT itself part of
// Vite's module graph, so there is no Vite-graph IMPORTER available to
// `import.meta.hot.accept("./dual-hmr-island.js", ...)` on this module's
// behalf the way M1's main.js does for counter-island.js. Self-accept is
// therefore the only viable HMR boundary reachable here.
//
// Same hydrate/dispose ABI as ../../../../../examples/js_island/counter.js
// and ./counter-island.js -- see dom/src/hydronium_dom/client/bootstrap.js
// for the contract (context.root/context.props,
// hydrate(context)/dispose(context)) -- and the same real npm dependency
// (nanoid) proving a genuine package-manager-resolved module graph.
import { nanoid } from "nanoid";

const state = new WeakMap();
let lastContext = null;

// `context.root` is the ISLAND's root element, which here is the SSR'd card
// -- not the button inside it. Adopt the existing button rather than writing
// textContent onto the card, which would delete the server-rendered <h3> and
// the button along with it. Falling back to root keeps this working if the
// island is ever rendered with the button as its own root.
function buttonOf(context) {
  return context.root.querySelector("#js-counter-btn") ?? context.root;
}

function render(context) {
  const button = buttonOf(context);
  const initial = context.props?.initial ?? 0;
  let count = initial;
  const sessionId = nanoid(8);

  button.textContent = `JS count: ${count}`;
  button.dataset.session = sessionId;

  const onClick = () => {
    count += 1;
    button.textContent = `JS count: ${count}`;
  };
  button.addEventListener("click", onClick);
  state.set(button, { onClick });
}

function cleanup(context) {
  const button = buttonOf(context);
  const entry = state.get(button);
  if (!entry) return;
  button.removeEventListener("click", entry.onClick);
  state.delete(button);
}

export function hydrate(context) {
  lastContext = context;
  render(context);
}

export function dispose(context) {
  cleanup(context);
  if (lastContext === context) lastContext = null;
}

// Self-accept: re-hydrates the SAME DOM node in place on every accepted
// update (dispose the old listener, run the new module's hydrate against
// the same context) -- mirrors what bootstrap.js's own
// activateIsland()/dispose() pair does for a real island swap, so this
// island keeps working exactly like a live one across an edit, not just
// visually updating once.
if (import.meta.hot) {
  import.meta.hot.accept((mod) => {
    if (!mod || !lastContext) return;
    cleanup(lastContext);
    mod.hydrate(lastContext);
  });
}
