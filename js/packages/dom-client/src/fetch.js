/*
 * Small, browser-native request primitive shared by Hydronium integrations.
 * It deliberately exposes HTTP responses as responses: callers decide whether
 * a 4xx/5xx is a route result, a form validation result, or an application
 * error. Only transport failures reject.
 */
export function createBrowserRequest(options = {}) {
  const fetchImpl = options.fetch ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") throw new Error("hydronium-dom: fetch is unavailable");

  return function request(input, init = {}) {
    const controller = new AbortController();
    const external = init.signal;
    let removeExternalAbort;
    if (external) {
      if (external.aborted) controller.abort(external.reason);
      else {
        const abort = () => controller.abort(external.reason);
        external.addEventListener?.("abort", abort, { once: true });
        removeExternalAbort = () => external.removeEventListener?.("abort", abort);
      }
    }
    const { signal: _ignored, ...rest } = init;
    const promise = Promise.resolve(fetchImpl(input, {
      credentials: "same-origin",
      ...rest,
      signal: controller.signal,
    })).finally(() => removeExternalAbort?.());
    return { promise, abort: () => controller.abort(), signal: controller.signal };
  };
}

export async function readResponse(response) {
  const contentType = response.headers?.get?.("content-type") ?? "";
  const body = contentType.toLowerCase().includes("json")
    ? await response.json()
    : await response.text();
  return { status: response.status, headers: { "content-type": contentType }, body };
}
