/**
 * Dev-only LIVE RELOAD for examples/meteorite_ssr -- deliberately not
 * HMR. This page is server-rendered with no hydrated Hydronium runtime
 * in the browser: no live ComponentInstance, no RefreshRegistry target,
 * nothing to patch in place. A full page reload is therefore the
 * honest, complete behavior for this page, not a placeholder for a
 * smarter one -- see docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md for the
 * state-preserving refresh proof, which runs against a page with a real
 * live runtime instead of this one.
 */
import { createDevTransport } from "./dev_transport.js";

const transport = createDevTransport("/__hydronium/watch");
transport.subscribe((event) => {
  if (event.type === "reload") {
    location.reload();
  }
});
