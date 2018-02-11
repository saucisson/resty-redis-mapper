local M = {}

M [#M+1] = function ()
  local Module = require "resty-redis-mapper"
  -- Instantiate the module:
  local module = Module {
    host  = "redis",
  }
  -- Create some types:
  local Dog = module:type "dog"
  local Cat = module:type "cat"
  -- Create a data:
  local data = Dog {}
  -- Delete a data:
  module [data] = nil
  -- Commit:
  Module.commit (module)
end

return M
