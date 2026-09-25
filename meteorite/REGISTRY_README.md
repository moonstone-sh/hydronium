# hydronium/meteorite

Meteorite development-host integration for Hydronium Lab. Applications use it
through the standalone `hydronium-lab` tool; production Meteorite graphs do
not include its routes.

The package owns the loopback Lab shell, exact asset routes, story catalog, and
isolated Ink sessions. `hydronium/lab` remains usable without Meteorite. A
custom mount prefix is supported through `hydronium_meteorite.lab.mount(app,
{ base_path = "/tools/lab" })`; the host contract injects all asset and
transport URLs into the browser shell.
