local ballad = require("ballad")

return ballad.partiture(function(p)
    local moonstone = p:use(ballad.plugins.moonstone)
    local layout = p:use(ballad.plugins.layout)

    local function package_orbit(name)
        -- hydronium/create's valid multi-profile lock currently fails an
        -- immediate `moon sync --locked` replay because Moonstone validates
        -- the first global realization for a package instead of the active
        -- profile. See ../moonstone/ISSUE-LOCKFILE.md. Keep this exception
        -- local until that defect is fixed.
        local sync_mode = name == "create" and "update" or "locked"
        return moonstone.orbit(name):partiture("partiture.lua"):run({
            sync = sync_mode,
            inputs = {
                "moonstone.toml",
                "moonstone.lock",
                "partiture.lua",
                "README.md",
                "REGISTRY_README.md",
                "src/**",
                "native/**",
                "nvim/**",
            },
        }):product("package")
    end

    local release = layout.directory({
        { from = package_orbit("core"), to = "hydronium" },
        { from = package_orbit("dom"), to = "hydronium-dom" },
        { from = package_orbit("luax"), to = "hydronium-luax" },
        { from = package_orbit("ink"), to = "hydronium-ink" },
        { from = package_orbit("ballad"), to = "hydronium-ballad" },
        { from = package_orbit("create"), to = "hydronium-create" },
    })

    p.sink.directory(release, { out = "dist/orbit", file_graph = true, product = "release" })
end)
