return {
  entry = "app",
  files = { "src/App.lua" },
  roots = { { path = "src", namespace = "app" } },
  entries = { { id = "app", path = "src/App.lua" } },
}
