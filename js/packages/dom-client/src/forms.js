/* Browser enhancement for hydronium.forms, composed through mount.luaGlobals. */

import { getCurrentDomEvent } from "./dom_bridge.js";
import { createBrowserRequest, readResponse } from "./fetch.js";

const EVENT_PAYLOADS = Symbol.for("hydronium.dom.eventPayloads");

function toLuaLiteral(value) {
  if (value === null || value === undefined) return "nil";
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `{ ${value.map(toLuaLiteral).join(", ")} }`;
  if (typeof value === "object") {
    return `{ ${Object.entries(value).map(([key, item]) => {
      const luaKey = /^[A-Za-z_][A-Za-z0-9_]*$/.test(key)
        ? key
        : `[${JSON.stringify(key)}]`;
      return `${luaKey} = ${toLuaLiteral(item)}`;
    }).join(", ")} }`;
  }
  throw new Error(`hydronium.forms: cannot serialize ${typeof value} across the Lua bridge`);
}

function valuesFromForm(form, FormDataImpl) {
  const values = {};
  for (const [name, value] of new FormDataImpl(form).entries()) {
    if (typeof value !== "string") {
      throw new Error("hydronium.forms: file controls require an explicit upload transport");
    }
    if (!(name in values)) values[name] = value;
    else if (Array.isArray(values[name])) values[name].push(value);
    else values[name] = [values[name], value];
  }
  return values;
}

/**
 * Return globals accepted directly by hydronium-dom's mount({ luaGlobals }).
 * The server should answer enhanced requests with a JSON action outcome;
 * an ordinary browser submission still uses the form's method/action.
 */
export function createFormGlobals(options = {}) {
  const request = options.request ?? createBrowserRequest({ fetch: options.fetch });
  const FormDataImpl = options.FormData ?? globalThis.FormData;
  const navigate = options.navigate ?? ((url) => globalThis.location?.assign?.(url));
  if (typeof request !== "function") throw new Error("hydronium.forms: request is unavailable");
  if (typeof FormDataImpl !== "function") throw new Error("hydronium.forms: FormData is unavailable");

  // DOM Events are not safe Wasmoon values and `currentTarget` is only live
  // during dispatch. The DOM bridge reads this registry before invoking Lua,
  // so the Lua callback receives an immutable literal instead of a dead Event.
  const payloads = globalThis[EVENT_PAYLOADS] ??= new Map();
  payloads.set("submit", (event) => {
    const form = event?.currentTarget ?? event?.target;
    if (!form) throw new Error("hydronium.forms: submit event has no form target");
    return toLuaLiteral(valuesFromForm(form, FormDataImpl));
  });

  return {
    __hydronium_form_prevent_default(event) {
      event ??= getCurrentDomEvent();
      event?.preventDefault?.();
    },
    __hydronium_form_values(event) {
      event ??= getCurrentDomEvent();
      const form = event?.currentTarget ?? event?.target ?? event;
      if (!form) throw new Error("hydronium.forms: submit event has no form target");
      return toLuaLiteral(valuesFromForm(form, FormDataImpl));
    },
    __hydronium_form_request(url, method, body, actionId, done) {
      const pending = request(url, {
        method,
        body,
        redirect: "manual",
        headers: {
          "content-type": "application/x-www-form-urlencoded;charset=UTF-8",
          accept: "application/json",
          "x-hydronium-action": actionId,
        },
      });
      pending.promise.then(async (response) => {
        const decoded = await readResponse(response);
        const outcome = typeof decoded.body === "object" && decoded.body !== null
          ? decoded.body
          : { ok: false, status: decoded.status, errors: { _form: [decoded.body || "Request failed"] } };
        const location = response.headers?.get?.("location");
        if (location && outcome.redirect == null) outcome.redirect = location;
        done(decoded.status, toLuaLiteral(outcome));
      }).catch((error) => {
        if (error?.name === "AbortError") return;
        done(0, toLuaLiteral({ ok: false, status: 0, errors: { _form: [String(error)] } }));
      });
      return pending.abort;
    },
    __hydronium_form_redirect(url) {
      navigate(String(url));
    },
  };
}

export { toLuaLiteral, valuesFromForm };
