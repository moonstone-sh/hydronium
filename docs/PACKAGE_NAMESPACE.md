# Package namespace

Hydronium is published from this repository under Moonstone's registry namespace
for the initial release line:

| Package | Current registry name | Future registry name |
| --- | --- | --- |
| Core | `moonstone/hydronium` | `hydronium/hydronium` |
| DOM | `moonstone/hydronium-dom` | `hydronium/hydronium-dom` |
| LUAX | `moonstone/hydronium-luax` | `hydronium/hydronium-luax` |
| Ink | `moonstone/hydronium-ink` | `hydronium/hydronium-ink` |
| Router (reserved until it lands) | `moonstone/hydronium-router` | `hydronium/hydronium-router` |
| Ballad plugins | `moonstone/hydronium-ballad` | `hydronium/hydronium-ballad` |
| Generator | `moonstone/hydronium-create` | `hydronium/hydronium-create` |

The source repository is `moonstone-sh/hydronium`. A future Hydronium
organization will own both the source repository and the `hydronium/*` registry
namespace. That move is a deliberate breaking package-name migration: it will
be announced with compatibility guidance rather than hidden behind aliases.

Lua module names such as `hydronium`, `hydronium_dom`, and `hydronium_luax` are
not changing.
