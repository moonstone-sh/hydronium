/** Abortable same-origin GET bridge for Hydronium route loaders. */
export function createHttpGlobals(options = {}) {
  const fetchImpl = options.fetch ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") throw new Error("hydronium-router: fetch is unavailable");

  return {
    __router_http_get(path, done) {
      if (typeof path !== "string" || !path.startsWith("/")) {
        throw new TypeError("hydronium-router: HTTP path must start with '/'");
      }
      const controller = new AbortController();
      Promise.resolve(fetchImpl(path, {
        method: "GET",
        credentials: "same-origin",
        headers: { accept: "application/json" },
        signal: controller.signal,
      })).then(async (response) => {
        const contentType = response.headers?.get?.("content-type") ?? "";
        const body = contentType.toLowerCase().includes("json")
          ? await response.json()
          : await response.text();
        if (!controller.signal.aborted) {
          done(JSON.stringify({ status: response.status, headers: { "content-type": contentType }, body }));
        }
      }).catch((error) => {
        if (!controller.signal.aborted) {
          done(JSON.stringify({ status: 0, error: String(error) }));
        }
      });
      return () => controller.abort();
    },
  };
}
