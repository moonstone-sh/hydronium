local H = require("hydronium.core")
local action = require("views.Actions").contact

return function(ctx)
	local valid, errors, output = action:check(ctx.values)
	if not valid then
		return H.action_fail({ values = ctx.values, errors = errors })
	end
	return H.action_ok({
		status = 201,
		data = { greeting = "Hello, " .. output.name },
		redirect = "/",
	})
end
