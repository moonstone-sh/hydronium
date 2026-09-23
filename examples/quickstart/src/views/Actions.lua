local H = require("hydronium.core")

local name_schema = {
	["~standard"] = {
		validate = function(values)
			if type(values.name) ~= "string" or values.name:match("^%s*$") then
				return { issues = { { path = { { key = "name" } }, message = "Enter your name" } } }
			end
			return { value = values }
		end,
	},
}

return {
	contact = H.action({
		id = "contact.submit",
		path = "/actions/contact",
		schema = name_schema,
	}),
}
