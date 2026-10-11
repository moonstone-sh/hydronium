-- Query-backed controlled table state. Inject a hydronium/query client to keep
-- the base table package independent of a transport or cache implementation.
local H = require("hydronium.core")
local tables = require("hydronium_table")
local M = {}
---@param options HydroniumRemoteTableOptions
---@return HydroniumRemoteTable
function M.create(options)
  if type(options) ~= "table" or type(options.client) ~= "table"
    or type(options.query) ~= "function" or options.key == nil then
    error("hydronium.table.remote requires client, key and query", 2)
  end
  local size = options.page_size or 20
  if type(size) ~= "number" or size < 1 or size == math.huge or size ~= math.floor(size) then
    error("hydronium.table.remote page_size must be a positive integer", 2)
  end
  local params = {page=0,page_size=size,sorting=options.sorting or {},filters=options.filters or {},search=options.search or ""}
  local parameters, set_parameters = H.createSignal(params)
  local state, set = H.createSignal({status="idle",fetching=false})
  local total, set_total = H.createSignal(0)
  local stop, alive, generation = nil, true, 0
  local change
  local function load(force)
    if not alive then return end
    generation = generation + 1
    local current = generation
    if stop then stop(); stop=nil end
    local snapshot = {page=params.page,page_size=size,sorting=params.sorting,filters=params.filters,search=params.search}
    local key = {options.key,snapshot}
    if force then options.client:invalidate(key,{refetch=false}) end
    local unsubscribe = options.client:observe({key=key,stale_time=options.stale_time,query=function(ctx,done)
      return options.query(snapshot,ctx,function(err,data)
        if err == nil and (type(data) ~= "table" or type(data.rows) ~= "table"
          or type(data.total) ~= "number" or data.total < 0 or data.total == math.huge or data.total ~= math.floor(data.total)) then
          done("Remote table requires {rows=..., total=nonnegative integer}.")
        else done(err,data) end
      end)
    end},function(value)
      if alive and current == generation then
        if value.status == "success" and not value.fetching then
          set_total(value.data.total)
          local last=math.max(0,math.ceil(value.data.total/size)-1)
          if params.page>last then change("page",last,true);return end
        end
        set(value)
      end
    end)
    if alive and current == generation then stop=unsubscribe else unsubscribe() end
  end
  change = function(name,value,force)
    if not alive then return end
    if params[name] == value then return end
    local next_params={}
    for key, previous in pairs(params) do next_params[key]=previous end
    next_params[name]=value
    if name ~= "page" then next_params.page=0;set_total(0) end
    params=next_params;set_parameters(params)
    load(force)
  end
  local model=tables.createTable({
    columns=options.columns, row_id=options.row_id, page_size=size,
    rows=function()local data=state().data;return data and data.rows or {} end,
    row_count=function()return total()end,
    manual_sorting=true,manual_filtering=true,manual_global_filter=true,manual_pagination=true,
    state={page=function()return parameters().page end,sorting=function()return parameters().sorting end,
      filters=function()return parameters().filters end,global_filter=function()return parameters().search end},
    on_state_change={page=function(value)change("page",value)end,
      sorting=function(value)change("sorting",value)end,
      filters=function(value)change("filters",value)end,
      global_filter=function(value)change("search",value or "")end},
  })
  local handle={model=model,state=state,total=total}
  function handle:refetch()load(true)end
  function handle:dispose()
    if not alive then return end
    alive=false;generation=generation+1
    if stop then stop();stop=nil end
  end
  if H.getScope() then H.onCleanup(function()handle:dispose()end)end
  load()
  return handle
end
return M
