# Host capabilities

A host capability is a versioned table of callable embedding bindings, scoped to one Lua VM. It is not process-wide singleton state. `hydronium.runtime.hosts` stores bindings in a normal cached Lua module; its registry does not live in `_G`.

`hosts.install(name, version, bindings)` returns the installed table and an idempotent release function. Reinstalling an occupied name is an error. Releasing an old installation cannot remove a later owner. Release unregisters the capability; it does not dispose DOM listeners or observers. Their owners must run the declared cleanup before releasing the host. `hosts.require(name, version)` diagnoses missing hosts and incompatible versions. `hosts.get` allows a missing host; `hosts.describe()` reports installed names, versions and method names without exposing callable values.

DOM bootstrap registers `dom@1` after Lua module preloading and before evaluating the application. The default Bridge API 2 provider installs bridge functions as yieldable host callbacks; temporary global setters are cleared after registration. The DOM reconciler receives the registry's bridge explicitly. DOM virtual hosts resolve the same capability. Legacy `__dom_*` globals remain available to old embeddings, and the no-argument DOM host falls back to them only when dom@1 is absent. Explicit `createDomHost(bridge)` injection continues to work.

The shared declarative contract is `hydronium_dom.host.contract`. It identifies `@hydronium-js/dom-client`'s `dom_bridge.js#createDomBridge` provider, required and optional methods, effects, lifecycle and cleanup. For example, `set_listener` has effect `dom.listen` and cleanup `remove_listener`; virtual observers return disposers. Its method list must match the JavaScript bridge.

## Ballad evidence

The Hydronium client resolver serializes `hydronium.host-capabilities.v1` into its `hy_module_graph` content, not only asset metadata. Each module records references and unresolved accesses with source lines. Provider evidence survives minification and both single/shared chunk bundling in `metadata.hydronium.host_capabilities`. Partitures may supply additional declarative contracts through `client.resolve`'s `host_capabilities` option.

The lexer inventory recognizes literal legacy reads/writes and locally bound `hosts.require/get/install("name", version)` calls. Comments and string contents do not become references. Computed lookup, environment escapes, raw access, unknown bindings/versions and registry alias mutation or escape conservatively mark `retain_all`. It is a literal inventory, not a complete lexical/dataflow proof.

Capability elimination is explicitly disabled. Existing module reachability remains active. The DOM host still validates all its mandatory methods, so a component with no visible event props does not prove that listeners are removable. Future elimination must resolve aliasing, dynamic props, cleanup and cross-language provider reachability before dropping code. Runtime usage observations can aid DevTools but never prove that unobserved code is unreachable.
