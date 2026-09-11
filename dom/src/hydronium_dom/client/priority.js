/*
  hydronium.client.priority -- resolves a hydration PRIORITY into a real
  promise that settles when that priority says "now".

  This exists because the priority was already real on the server side and
  had no consumer on the client side. `dom/src/hydronium_dom/server/init.lua`
  has emitted a per-island `hydrate` field into the client plan since
  islands v1 (`hydrate = raw_props.hydrate or "load"`), and
  examples/meteorite_ssr's /islands and /mixed routes have both been
  declaring `hydrate = "visible"` on real islands this whole time -- but
  nothing in the browser ever read the field, so every island that asked to
  be deferred was activated immediately anyway. This module is the missing
  half, shared deliberately by BOTH consumers so they cannot drift:

    - ./bootstrap.js  -- schedules each `interpreter: "js"` island by the
      priority its own client-plan entry declares.
    - ./mount.js      -- the `defer` option on a root `d.lua.mount`, which
      has no client-plan entry to read a priority from and so takes one
      directly from the app.

  SUPPORTED PRIORITIES

    "load"     Immediately. The default, and what every island did
               unconditionally before this module existed -- so a page that
               declares nothing keeps its exact previous behaviour.
    "idle"     `requestIdleCallback`, i.e. once the browser has no
               higher-priority work left. Falls back to a macrotask where
               that API does not exist (Safari <16.4, jsdom).
    "visible"  `IntersectionObserver`, i.e. once the island's own DOM is
               at (or near) the viewport. Falls back to "load" where the
               API is missing, because a never-resolving promise would
               mean an island that silently never hydrates at all --
               strictly worse than hydrating too eagerly.

  An unrecognized priority also falls back to "load", for the same reason:
  a typo in an app's `hydrate` prop should cost eagerness, never a
  permanently dead island. It is reported through `onUnknown` so a caller
  can surface it rather than swallow it.

  WHY A PROMISE AND NOT A CALLBACK: both consumers already await things
  (`bootstrap.js` awaits a dynamic `import()`, `mount.js` awaits the VM
  boot), and a promise composes with those directly -- `Promise.all` over a
  page's islands, `await` before a mount -- without either of them growing
  its own scheduling state machine.
*/

/** Priorities this module knows how to defer. Anything else means "load". */
export const PRIORITIES = ["load", "idle", "visible"];

const IDLE_TIMEOUT_MS = 2000;

/*
  Deliberately non-zero: an island 200px below the fold is one small scroll
  from being looked at, and hydration is not instant. Starting slightly
  early is what makes "visible" feel like the content was simply ready,
  rather than like it stalled on arrival. Same default order of magnitude
  as the major frameworks' own `client:visible` implementations.
*/
const VISIBLE_ROOT_MARGIN = "200px";

function whenIdle() {
  return new Promise((resolve) => {
    if (typeof requestIdleCallback === "function") {
      // The timeout matters: with no idle period at all (a page that stays
      // busy), a bare requestIdleCallback can be starved indefinitely.
      requestIdleCallback(() => resolve(), { timeout: IDLE_TIMEOUT_MS });
    } else {
      setTimeout(resolve, 0);
    }
  });
}

function whenVisible(element) {
  if (typeof IntersectionObserver !== "function" || !element) return Promise.resolve();
  return new Promise((resolve) => {
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            // Disconnect BEFORE resolving: this observer's only job is the
            // first intersection, and leaving it attached would keep the
            // element (and this closure) observed for the page's lifetime.
            observer.disconnect();
            resolve();
            return;
          }
        }
      },
      { rootMargin: VISIBLE_ROOT_MARGIN }
    );
    observer.observe(element);
  });
}

/**
 * Resolves once `priority` says the work may run.
 *
 * @param {string|((el: Element|null) => any)} priority One of PRIORITIES, or a
 *   function returning a promise -- the escape hatch for an app with a real
 *   trigger of its own (a route transition, a media query, a user gesture)
 *   that no fixed vocabulary here could cover.
 * @param {Element|null} element The island's own DOM, used by "visible".
 * @param {(p: string) => void} [onUnknown] Called with the offending value
 *   when `priority` is not recognized (it is then treated as "load").
 * @returns {Promise<void>}
 */
export function whenPriority(priority, element, onUnknown) {
  if (typeof priority === "function") return Promise.resolve(priority(element));
  if (priority === "idle") return whenIdle();
  if (priority === "visible") return whenVisible(element);
  if (priority !== "load" && priority != null && onUnknown) onUnknown(String(priority));
  return Promise.resolve();
}
