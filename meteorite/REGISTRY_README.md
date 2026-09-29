# hydronium/meteorite

Meteorite development-host integration for Hydronium Lab. Applications use it
through the standalone `hydronium-lab` tool; production Meteorite graphs do
not include its routes.

The package owns the loopback Lab shell, exact asset routes, story catalog, and
isolated Ink sessions. `hydronium/lab` remains usable without Meteorite. A
custom mount prefix is supported through `hydronium_meteorite.lab.mount(app,
{ base_path = "/tools/lab" })`; the host contract injects all asset and
transport URLs into the browser shell.

The adapter mounts the complete Workbench/xterm asset set, including shared
controls, so consumers do not need to add external xterm scripts or styles.
With the unreleased Lab customization API, `hydronium-lab customize` creates
an optional project-owned workbench. A story's `controls_view` supplies DOM
controls while its preview remains Ink. See
[Lab controls and playback](../docs/LAB_CONTROLS.md).
