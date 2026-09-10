# Hydronium Ink

`moonstone/hydronium-ink` is Hydronium's terminal host, with Box, Text, and Newline
intrinsics backed by Yoga layout.

```sh
moon add moonstone/hydronium-ink
```

It installs the `hydronium_ink` Lua namespace, resolves `hydronium`
automatically, and projects the matching prebuilt Yoga library into the
Moonstone runtime environment. Supported release targets are arm64 and x86-64
macOS or glibc Linux; Windows is not supported yet.
