-- luacheck: new globals ngx

-- Add path for openresty modules:
package.path  = "/usr/local/openresty/lualib/?.lua;" .. package.path
package.cpath = "/usr/local/openresty/lualib/?.so;"  .. package.cpath

describe ("resty-redis-mapper", function ()

  local Redis, redis

  before_each (function ()
    Redis = require "resty.redis"
    redis = Redis:new ()
    assert (redis:connect ("redis", 6379))
    redis:flushall ()
  end)

  after_each (function ()
    redis:close ()
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
        local _ = module:type "type"
      end)
    end)

  end)

  it ("can commit", function ()
    assert.are.equal (redis:dbsize (), 0)
    local Module = require "resty-redis-mapper"
    local module = Module {
      host  = "redis",
    }
    local Dog = module:type "dog"
    local _   = Dog {}
    assert.has.no.errors (function ()
      module:commit ()
    end)
    assert.are.equal (redis:dbsize (), 2)
  end)

  it ("cannot do anything after commit", function ()
    assert.are.equal (redis:dbsize (), 0)
    local Module = require "resty-redis-mapper"
    local module = Module {
      host  = "redis",
    }
    local Dog = module:type "dog"
    local _   = Dog {}
    assert.has.no.errors (function ()
      module:commit ()
    end)
    assert.has.errors (function ()
      local _ = Dog {}
    end)
  end)

  describe ("objects", function ()

    it ("can be created", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      local Type = module:type "type"
      assert.has.no.errors (function ()
        local _ = Type {}
      end)
    end)

    it ("can be deleted", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      local Type   = module:type "type"
      local object = Type {}
      assert.has.no.errors (function ()
        module [object] = nil
      end)
    end)

    it ("handle equality before commit", function ()
      local Module = require "resty-redis-mapper"
      local module = Module {
        host  = "redis",
      }
      local Type   = module:type "type"
      local object = Type {}
      local o1  = module [object]
      local o2  = module [object]
      assert.are.same (object, o1)
      assert.are.same (object, o2)
    end)

    it ("can be initialized", function ()
      local Module = require "resty-redis-mapper"
      local id
      do
        local module = Module {
          host  = "redis",
        }
        local Type = module:type "type"
        local object = Type {
          field = "value",
        }
        assert.are.equal (object.field, "value")
        id = module:identifier (object)
        module:commit ()
      end
      do
        local module = Module {
          host  = "redis",
        }
        local _      = module:type "type"
        local object = module [id]
        assert.are.equal (object.field, "value")
      end
    end)

    it ("can be updated", function ()
      local Module = require "resty-redis-mapper"
      local id
      do
        local module = Module {
          host  = "redis",
        }
        local Type   = module:type "type"
        local object = Type {}
        object.outer = "value"
        object.inner = {
          x = true,
        }
        object.inner.y = 1
        id = module:identifier (object)
        module:commit ()
      end
      do
        local module = Module {
          host  = "redis",
        }
        local _      = module:type "type"
        local object = module [id]
        assert.are.equal (object.outer  , "value")
        assert.are.equal (object.inner.x, true)
        assert.are.equal (object.inner.y, 1)
      end
    end)

    it ("can be updated with other objects", function ()
      local Module = require "resty-redis-mapper"
      local id_other, id_object
      do
        local module = Module {
          host  = "redis",
        }
        local Type   = module:type "type"
        local other  = Type {}
        local object = Type {}
        object [other] = true
        object.outer = other
        object.inner = {
          x = other,
        }
        id_other  = module:identifier (other )
        id_object = module:identifier (object)
        module:commit ()
      end
      do
        local module = Module {
          host  = "redis",
        }
        local _      = module:type "type"
        local other  = module [id_other ]
        local object = module [id_object]
        assert.are.equal (object [other], true)
        assert.are.equal (object.outer  , other)
        assert.are.equal (object.inner.x, other)
      end
    end)

    it ("can be iterated", function ()
      local Module = require "resty-redis-mapper"
      local id_other, id_object
      do
        local module = Module {
          host  = "redis",
        }
        local Type   = module:type "type"
        local other  = Type {}
        local object = Type {}
        object [1] = true
        object [2] = other
        id_other  = module:identifier (other )
        id_object = module:identifier (object)
        module:commit ()
      end
      do
        local module = Module {
          host  = "redis",
        }
        local _      = module:type "type"
        local other  = module [id_other ]
        local object = module [id_object]
        assert.are.equal (#object, 2)
        do
          local results = {}
          for _, x in ipairs (object) do
            results [#results+1] = x
          end
          assert.are.same (results, { true, other })
        end
        do
          local keys = {}
          for key in pairs (object) do
            keys [#keys+1] = key
          end
          assert.are.equal (#keys, 2)
        end
      end
    end)

  end)

  it ("can commit", function ()
    assert.are.equal (redis:dbsize (), 0)
    local Module = require "resty-redis-mapper"
    local module = Module {
      host  = "redis",
    }
    local Dog   = module:type "dog"
    local start = os.time ()
    local i     = 0
    repeat
      local _ = Dog {}
      i = i + 1
    until os.time () - start >= 2
    module:commit ()
    print ("Can perform " .. tostring (i/3) .. " commits per second.")
  end)

end)
