-- luacheck: new globals ngx

local type_of = type
local Hashids = require "hashids"
local Json    = require "cjson"
local Redis   = require "resty.redis"

local function empty ()
  local result = {}
  for _, key in ipairs {
    "__len",
    "__call",
    "__tostring",
    "__pairs", "__ipairs",
    "__unm", "__add", "__sub", "__mul", "__div", "__idiv", "__mod", "__pow",
    "__concat",
    "__band", "__bor", "__bxor", "__bnot", "__bshl", "__bshr",
    "__eq", "__lt", "__le",
  } do
    result [key] = function ()
      assert (false, key)
    end
  end
  return result
end

local M = setmetatable ({}, empty ())

-- This whole module uses the proxy pattern to hide data.
-- All objects returned to the caller are proxies,
-- and the corresponding real data is stored in the `modules` table.
local modules = setmetatable ({}, { __mode = "k" })

-- This table keeps track of the data that are alive.
-- It is required by the `newproxy` hack.
local alive = setmetatable ({}, { __mode = "k" })

-- The default values for options:
local defaults = {}

-- The redis host:
defaults.host = "127.0.0.1"

-- The redis port:
defaults.port = 6379

-- The redis timeout:
defaults.timeout = 1000 -- 1 second

-- The redis idle time:
defaults.idle = 10000 -- 10 seconds

-- The redis pool size:
defaults.pool = 100

-- The special key for generating unique identifiers:
defaults.identifiers = "@identifiers"

-- The encoding function for unique identifiers:
local hashids = Hashids.new ("a default salt", 8)
defaults.encode_key = function (key)
  assert (type_of (key) == "number", key)
  return hashids:encode (key)
end

-- The encoding and decoding functions for data:
local json = Json.new ()
defaults.encode_value = function (value)
  return json.encode (value)
end
defaults.decode_value = function (value)
  if value == ngx.null then
    return nil
  end
  return Json.decode (value)
end

-- Create a new instance of the module:
getmetatable (M).__call = function (_, options)
  assert (options == nil or type_of (options) == "table")
  -- Create instance, and set the __gc hack if `newproxy` exists:
  local module    = setmetatable ({}, M)
  modules [module] = {}
  if _G.newproxy then
    local proxy = _G.newproxy (true)
    getmetatable (proxy).__gc = function ()
      M.__gc (module)
    end
    alive [module] = proxy
  end
  local m = modules [module]
  -- Fill module with options or defaults:
  for key, default in pairs (defaults) do
    assert (options [key] == nil or type_of (options [key]) == type_of (default))
    m [key] = options [key] or default
  end
  -- Inconsistent flag warns that the instance should not be used,
  -- because it has reached an inconsistent state with its objects:
  m.consistent = true
  -- Unique table for data and subdata:
  m.objects  = setmetatable ({}, { __mode = "v" })
  m.metadata = setmetatable ({}, { __mode = "v" })
  m.contents = setmetatable ({}, { __mode = "v" })
  -- Set of updated data:
  m.updated = {}
  -- Types:
  m.types = setmetatable ({}, { __mode = "v" })
  -- Redis connection:
  m.redis = Redis:new ()
  m.redis:set_timeout (m.timeout)
  assert (m.redis:connect (m.host, m.port))
  return module
end

-- Destroy an instance of the module when it is no longer used:
function M.__gc (module)
  assert (getmetatable (module) == M)
  local m = modules [module]
  -- It cancels the changes that have been done,
  -- as the redis connection can be reused.
  -- Cancel the transaction:
  m.redis:discard ()
  -- Release redis connection:
  assert (m.redis:set_keepalive (m.idle, m.pool))
  -- TODO: check if `assert` in `__gc` creates no problem.
  -- The module instance must not be used after a `__gc`:
  m.consistent = false
end

function M.identifier (module, object)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  return m.metadata [object]
     and m.metadata [object].identifier
      or nil
end

-- Commit the changes:
function M.commit (module)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  m.redis:multi ()
  -- Set all updated entities:
  for data, value in pairs (m.updated) do
    local identifier = m.metadata [data].identifier
    if value == ngx.null then
      -- Delete from redis:
      assert (m.redis:del (identifier))
    else
      -- Set in redis:
      assert (m.redis:set (identifier, m.encode_value ({
        metadata = m.metadata [data],
        contents = m.contents [data],
      })))
    end
  end
  -- Clear updated entities:
  m.updated = {}
  -- Commit changes to redis:
  m.consistent = false
  assert (m.redis:exec ())
  -- If the assertion fails, then the whole module instance is
  -- in a non consistent state, because data has been changed and is invalid
  -- for Redis. The assertion should not be recovered, except at the topmost
  -- level, where a new module instance is created, and the whole query
  -- performed again.
  return true
end

-- Get an object:
function M.__index (module, key)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  -- If the key refers to a method, return it:
  if M [key] then
    return M [key]
  end
  -- Else, the key refers to an object that can exist or be missing.
  -- If the key is an object, get its identifier:
  key = m.metadata [key]
    and m.metadata [key].identifier
     or key
  -- If this object has already been loaded, return it:
  if m.objects [key] and m.objects [key] == ngx.null then
    return nil
  elseif m.objects [key] then
    return m.objects [key]
  end
  -- Else, load the object from redis,
  -- and watch its key to detect changes if needed:
  m.redis:watch (key)
  local data = m.redis:get (key)
  if data == ngx.null then
    return nil
  end
  data = m.decode_value (data)
  -- Load the object:
  local type   = m.types [data.metadata.type]
  local object = type:__empty (data.metadata.identifier)
  type.__create (object, data.contents)
  m.objects [key] = object
  return object
end

-- Update an object:
function M.__newindex (module, key, value)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  -- If the key is an object, get its identifier:
  key = m.metadata [key]
    and m.metadata [key].identifier
     or key
  -- In all cases, delete the previous object:
  -- Call the destructor of data:
  local previous = module [key]
  getmetatable (previous).__delete (previous)
  -- Delete from unique table:
  -- `ngx.null` marks it as to delete from redis
  m.objects [key     ] = ngx.null
  m.updated [previous] = true
  -- If the value is not nil, replace object:
  if value ~= nil then
    -- Clone object:
    local type   = assert (getmetatable (value))
    local object = type:__empty (m.metadata [value].identifier)
    type.__create (object, Json.decode (Json.encode (m.contents [value])))
  end
end

-- The encoded object contains the following fields:
-- * __identifier: its unique identifier;
-- * __type: the name of its type;
-- * __contents: its contents.
-- Create a type:
function M.type (module, name)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  assert (type_of (name) == "string")
  -- Metatable for subdata:
  local table = {}
  -- Metatable for type:
  local type  = setmetatable ({}, {
    __call = function (t, contents)
      assert (m.consistent)
      -- Generate a key for the new data:
      local key = m.encode_key (m.redis:incr (m.identifiers))
      -- Create object, but do not insert it into redis,
      -- as the commit will do it:
      local object = t:__empty (key)
      t.__create (object, contents)
      return object
    end,
    __tostring = function (_)
      return name
    end,
  })
  -- Store type in module:
  m.types [name] = type
  -- Define metamethods:
  type.__empty = function (_, identifier)
    assert (type_of (identifier) == "string")
    local instance = setmetatable ({}, type)
    m.metadata [instance] = {
      identifier = identifier,
      type       = tostring (type),
    }
    m.contents [instance  ] = {}
    m.objects  [identifier] = instance
    m.updated  [instance  ] = true
    return instance
  end
  type.__create = function (instance, contents)
    assert (m.consistent)
    -- Set the contents of the object:
    m.contents [instance] = contents
    m.updated  [instance] = true
  end
  type.__delete = function (instance)
    assert (m.consistent)
    -- Do nothing:
    local _ = instance
    m.updated [instance] = true
  end
  type.__tostring = function (instance)
    assert (m.consistent)
    local meta = m.metadata [instance]
    local data = m.contents [instance]
    return meta.identifier
        .. " : "
        .. meta.type
        .. " = "
        .. Json.encode (data)
  end

  -- Unique table for subdata:
  local subdata = setmetatable ({}, { __mode = "v" })
  local unique  = setmetatable ({}, { __mode = "v" })
  type.__index = function (instance, key)
    assert (m.consistent)
    assert (m.metadata [instance] or subdata [instance])
    -- If in an object and the key starts with "__", rawget it:
    if  m.metadata [instance]
    and type_of (key) == "string" and key:match "^__" then
      return rawget (instance, key)
    end
    -- If in an object and the key refers to a method, return it directly:
    if m.metadata [instance] and type [key] then
      return type [key]
    end
    -- Past this line, the key should be searched within contents.
    -- If the key refers to an object, obtain its identifier:
    key = m.metadata [key]
      and m.metadata [key].identifier
       or key
    -- Get the current location within the object:
    local current = m.contents [instance]
                 or subdata [instance].contents
    assert (type_of (current) == "table")
    current = current [key]
    -- If there is not subdata, return nil:
    if current == nil then
      return nil
    end
    -- If the obtained value is a reference to an object, convert it:
    if type_of (current) == "string" and current:match "^__" then
      local identifier = current:match "^__(.*)$"
      return module [identifier]
    end
    if type_of (current) ~= "table" then
      return current
    end
    -- Else, search for a unique representation:
    if unique [current] then
      return unique [current]
    end
    -- If it is a subdata, compute it:
    local result = setmetatable ({}, table)
    subdata [result] = {
      contents = current,
      root     = subdata [instance]
             and subdata [instance].root
              or instance,
    }
    unique [current] = result
    return result
  end
  type.__newindex = function (instance, key, value)
    assert (m.consistent)
    assert (m.metadata [instance] or subdata [instance])
    -- If in an object and the key starts with "__", rawget it:
    if  m.metadata [instance]
    and type_of (key) == "string" and key:match "^__" then
      return rawget (instance, key)
    end
    -- If in an object and the key refers to a method, return it directly:
    if m.metadata [instance] and type [key] then
      return type [key]
    end
    -- Past this line, the key should be searched within contents.
    -- If the key refers to an object, obtain its identifier:
    key = m.metadata [key]
      and m.metadata [key].identifier
       or key
    -- If the value refers to an object, obtain its identifier:
    value = m.metadata [value]
        and m.metadata [value].identifier
         or value
    -- Copy key and value to avoid shared data structures:
    key   = Json.decode (Json.encode (key  ))
    value = Json.decode (Json.encode (value))
    -- Get the current location within the object:
    local current = m.contents [instance]
                 or subdata [instance].contents
    assert (type_of (current) == "table")
    -- Update the value:
    -- Thanks to unique table, the change should be correctly propagated
    -- to other references.
    current [key] = value
    -- Mark as updated:
    local root = m.metadata [instance]
             and instance
              or subdata [instance].root
    m.updated [root] = true
  end
  table.__index    = type.__index
  table.__newindex = type.__newindex
  return type
end

return M
