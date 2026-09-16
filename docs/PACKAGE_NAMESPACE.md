# Package namespace

Hydronium is published under its own Hydronium organization's `hydronium/*`
registry namespace.

| Package | Former registry name | Current registry name |
| --- | --- | --- |
| Core | `moonstone/hydronium` | `hydronium/core` |
| DOM | `moonstone/hydronium-dom` | `hydronium/dom` |
| LUAX | `moonstone/hydronium-luax` | `hydronium/luax` |
| Ink | `moonstone/hydronium-ink` | `hydronium/ink` |
| Router | `moonstone/hydronium-router` | `hydronium/router` |
| Ballad plugins | `moonstone/hydronium-ballad` | `hydronium/ballad` |
| Generator | `moonstone/hydronium-create` | `hydronium/create` |
| Developer CLI | `moonstone/hydronium-cli` | `hydronium/cli` |

The source repository is `moonstone-sh/hydronium`; the Hydronium organization
owns the `hydronium/*` registry namespace independently of that repo's own
location. This was a deliberate breaking package-name migration from the
earlier `moonstone/hydronium-*` names (note: local names are trimmed rather
than repeating `hydronium-` under the new namespace, e.g. `hydronium/dom`,
not `hydronium/hydronium-dom`, and core is `hydronium/core` rather than the
self-referential `hydronium/hydronium`).

Lua module names such as `hydronium`, `hydronium_dom`, and `hydronium_luax`
are not changing.
