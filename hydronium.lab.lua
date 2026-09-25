-- hydronium-lab configuration: Ink stories rendered in a browser virtual
-- terminal (`hydronium-lab dev`).
--
-- The stories under these roots are the CLI's own components. That is
-- deliberate dogfooding: `hydronium dev` is Ink's most substantial consumer,
-- and ink-lab is Ink's tooling, so pointing one at the other exercises both.
-- Before this, the entire repository contained a single ten-line story
-- fixture, under meteorite's test directory.
return {
  title = "Hydronium CLI & Create",
  roots = { "cli/src/ui", "create/src/create/ui" },
  -- Stories import their sibling application modules, while discovery stays
  -- intentionally limited to the two UI folders above.
  module_roots = { "cli/src", "create/src" },
}
