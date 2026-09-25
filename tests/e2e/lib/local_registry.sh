#!/usr/bin/env bash
# Shared helpers for gates that consume Hydronium from a disposable local
# file registry. Source this file; it defines functions only.

# The same defaulting bug applies one level down: every exported package
# descriptor's own `[[dependencies]]` on another hydronium/* package (e.g.
# hydronium/cli -> hydronium/ink) carries `resolver = "moonstone"` --
# Moonstone's registry-package export always writes this -- and never an
# explicit `registry = "..."`. Moonstone's StoreDependency.toSpecString()
# (src/core/domain/manifest.zig) falls back to that resolver string as the
# registry IDENTITY whenever no explicit registry is set, so the *entire*
# transitive hydronium/* graph resolves only from whatever registry happens
# to be literally named "moonstone", never from this disposable local one,
# no matter its priority. A descriptor's `registry = "<name>"` key (as
# opposed to `resolver = "<name>"`) does NOT trip Moonstone's
# DependencyRegistryConflict check and flows through as a real registry
# identity lookup against `[[registries]]` -- so rewrite descriptors to use
# it before publishing them into the disposable registry.
rewrite_hydronium_deps() {
  local src="$1" dst="$2" registry_name="$3"
  awk -v want="$registry_name" '
    function flush_block() {
      if (in_dep && name ~ /^hydronium\//) {
        gsub(/resolver = "moonstone"/, "registry = \"" want "\"", block)
      }
      printf "%s", block
      block = ""; in_dep = 0; name = ""
    }
    /^\[\[dependencies\]\]/ {
      flush_block()
      in_dep = 1
      block = $0 "\n"
      next
    }
    /^\[/ {
      flush_block()
      print
      next
    }
    {
      if (in_dep) {
        block = block $0 "\n"
        if ($0 ~ /^name[ \t]*=/) {
          name = $0
          sub(/^name[ \t]*=[ \t]*"/, "", name)
          sub(/"[ \t]*$/, "", name)
        }
      } else {
        print
      }
    }
    END { flush_block() }
  ' "$src" > "$dst"
}
