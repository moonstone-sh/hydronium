/** Abortable same-origin GET bridge for Hydronium route loaders. */
export function createHttpGlobals(options = {}) {
  // `request` is normally createBrowserRequest() from hydronium-dom.  Keep a
  // compatibility fallback for standalone router consumers until their mount
  // setup adopts the shared DOM helper.
  const request = options.request ?? ((path, init) => {
    const controller = new AbortController();
    return {
      promise: Promise.resolve((options.fetch ?? globalThis.fetch)(path, { credentials: "same-origin", ...init, signal: controller.signal })),
      abort: () => controller.abort(), signal: controller.signal,
    };
  });
  if (typeof request !== "function") throw new Error("hydronium-router: request is unavailable");

  return {
    __router_http_get(path, done) {
      if (typeof path !== "string" || !path.startsWith("/")) {
        throw new TypeError("hydronium-router: HTTP path must start with '/'");
      }
      const pending = request(path, {
        method: "GET",
        credentials: "same-origin",
        headers: { accept: "application/json" },
      });
      pending.promise.then(async (response) => {
        const contentType = response.headers?.get?.("content-type") ?? "";
        const body = contentType.toLowerCase().includes("json")
          ? await response.json()
          : await response.text();
        if (!pending.signal.aborted) {
          done(JSON.stringify({ status: response.status, headers: { "content-type": contentType }, body }));
        }
      }).catch((error) => {
        if (!pending.signal.aborted) {
          done(JSON.stringify({ status: 0, error: String(error) }));
        }
      });
      return pending.abort;
    },
  };
}
