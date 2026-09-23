# Hydronium Lab

Host-neutral story metadata and shared Workbench UI for Hydronium development
tools. The package owns story validation, deterministic discovery planning,
explicit registry composition, a JSON-safe catalog projection, and the browser
chrome shared by DOM and Ink renderers. Renderer packages own their preview
surface and interactions; host adapters own HTTP routes and process lifecycle.

Source lives under `src/hydronium_lab`. Run repository tests from the Hydronium
root:

```sh
moon exec -- luajit tests/runner.lua tests/host/ink_lab_spec.lua
```

Build the registry artifact from this directory with `moon run package`.

`hydronium_lab.discovery.plan(paths, opts)` consumes a host-supplied,
project-relative path inventory. It performs no filesystem calls. The
standalone `hydronium-lab` executable provides portable enumeration and hands
the resulting launch request to an explicitly configured host adapter.
