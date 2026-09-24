local ballad = require("ballad")

return ballad.partiture(function(p)
    local moonstone = p:use(ballad.plugins.moonstone)
    local layout = p:use(ballad.plugins.layout)

    local function package_orbit(name)
        return moonstone.orbit(name):partiture("partiture.lua"):run({
            sync = "locked",
            inputs = {
                "moonstone.toml",
                "moonstone.lock",
                "partiture.lua",
                "README.md",
                "REGISTRY_README.md",
                "src/**",
                "client/**",
                "native/**",
                "nvim/**",
            },
        }):product("package")
    end

    local release = layout.directory({
        { from = package_orbit("core"), to = "core" },
        { from = package_orbit("dom"), to = "dom" },
        { from = package_orbit("luax"), to = "luax" },
        { from = package_orbit("oklab-utils"), to = "oklab-utils" },
        { from = package_orbit("ink"), to = "ink" },
        { from = package_orbit("lab"), to = "lab" },
        { from = package_orbit("lab-cli"), to = "lab-cli" },
        { from = package_orbit("ink-lab"), to = "ink-lab" },
        { from = package_orbit("meteorite"), to = "meteorite" },
        { from = package_orbit("router"), to = "router" },
        { from = package_orbit("query"), to = "query" },
        { from = package_orbit("virtual"), to = "virtual" },
        { from = package_orbit("table"), to = "table" },
        { from = package_orbit("ballad"), to = "ballad" },
        { from = package_orbit("create"), to = "create" },
        { from = package_orbit("cli"), to = "cli" },
    })

    p.sink.directory(release, { out = "dist/orbit", file_graph = true, product = "release" })
end)
