/**
 * Dev-only LIVE RELOAD for examples/meteorite_ssr -- deliberately not
 * HMR. This page is server-rendered with no hydrated Hydronium runtime
 * in the browser: no live ComponentInstance, no RefreshRegistry target,
 * nothing to patch in place. A full page reload is therefore the
 * honest, complete behavior for this page, not a placeholder for a
 * smarter one -- see docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md for the
 * state-preserving refresh proof, which runs against a page with a real
 * live runtime instead of this one.
 *
 * KEPT, NOT RETIRED, now that ./hmr.js exists. The two are not competing
 * implementations of the same thing: hmr.js requires a live client Lua
 * VM to swap a module inside (it takes the engine `mount()` returned),
 * and a page that never boots one has nothing for it to act on. For
 * those pages -- pure SSR output, a static docs page, any project not
 * using `mount()` -- a full reload remains the complete and correct
 * behavior, not a degraded one. Use hmr.js wherever a VM exists (it
 * falls back to a full page reload by itself whenever a hot swap cannot
 * be proven to have worked); use this where one does not.
 */
import { createDevTransport } from "./dev_transport.js";

const transport = createDevTransport("/__hydronium/watch");
transport.subscribe((event) => {
  if (event.type === "reload") {
    location.reload();
  }
});
