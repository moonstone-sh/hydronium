local lab = require("hydronium_lab")
return lab.story({id="button",renderer="dom",render=function() return require("hydronium").h("button",nil,"Hello") end})
