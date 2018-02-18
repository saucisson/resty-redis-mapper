-- luacheck: new globals ngx
-- Add a path required for cjson:
package.path  = "/usr/local/openresty/lualib/?.lua;" .. package.path
package.cpath = "/usr/local/openresty/lualib/?.so;"  .. package.cpath

describe ("resty-redis-mapper", function ()

  before_each (function ()
    local Redis = require "resty.redis"
    local redis = Redis:new ()
    assert (redis:connect ("redis", 6379))
    redis:flushall ()
  end)

  it ("can be required", function ()
    assert.has.no.errors (function ()
      local _ = require "resty-redis-mapper"
    end)
  end)

  it ("can be instantiated", function ()
    local Module = require "resty-redis-mapper"
    assert.has.no.errors (function ()
      local _ = Module {
        host  = "redis",
      }
    end)
  end)

  describe ("types", function ()

    it ("can be created", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      assert.has.no.errors (function ()
        local _ = module:type "dog"
      end)
    end)

    it ("cannot update __index", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      local Dog = module:type "dog"
      assert.has.errors (function ()
        Dog.__index = function () end
      end)
    end)

    it ("cannot update __newindex", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      local Dog = module:type "dog"
      assert.has.errors (function ()
        Dog.__newindex = function () end
      end)
    end)

    it ("cannot update __call", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      local Dog = module:type "dog"
      assert.has.errors (function ()
        Dog.__call = function () end
      end)
    end)

  end)

  describe ("objects", function ()

    it ("can be created", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      local Dog = module:type "dog"
      assert.has.no.errors (function ()
        local _ = Dog {}
      end)
    end)

    it ("can be deleted", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      local Dog = module:type "dog"
      local dog = Dog {}
      assert.has.no.errors (function ()
        module [dog] = nil
      end)
    end)

  end)

  it ("can commit", function ()
    local Module = require "resty-redis-mapper"
    local module = Module {
      host  = "redis",
    }
    local Dog = module:type "dog"
    local _   = Dog {}
    assert.has.no.errors (function ()
      module:commit ()
    end)
    local Redis = require "resty.redis"
    local redis = Redis:new ()
    assert (redis:connect ("redis", 6379))
    assert.are.equal (redis:dbsize (), 2)
  end)

end)
