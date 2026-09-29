// Marshal functions at the embedding boundary, then store them in a Lua module.
// Temporary globals are transport slots, not the runtime capability registry.
let installation = 0;
export async function installHostCapability(lua, {name, version, bindings, legacyPrefix}) {
  if (!/^[A-Za-z][\w.-]*$/.test(name) || !Number.isInteger(version) || version < 1) {
    throw new TypeError('Invalid host capability name/version');
  }
  const entries = Object.entries(bindings).sort(([a], [b]) => a.localeCompare(b));
  for (const [key, fn] of entries) {
    if (!/^[A-Za-z_][\w]*$/.test(key) || typeof fn !== 'function') throw new TypeError(`Invalid host binding: ${key}`);
  }
  if (legacyPrefix != null && !/^[A-Za-z_][\w]*$/.test(legacyPrefix)) throw new TypeError('Invalid legacy host prefix');
  const prefix = `__hydronium_host_transport_${++installation}_`;
  try {
    for (const [key, fn] of entries) lua.global.set(prefix + key, fn);
    const fields = entries.map(([key]) => `${key} = ${prefix}${key}`).join(',\n');
    await lua.doString(`require("hydronium.runtime.hosts").install(${JSON.stringify(name)}, ${version}, {\n${fields}\n})`);
    if (legacyPrefix) for (const [key, fn] of entries) lua.global.set(legacyPrefix + key, fn);
  } finally {
    for (const [key] of entries) lua.global.set(prefix + key, undefined);
  }
}
