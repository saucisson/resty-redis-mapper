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

local M    = setmetatable ({}, empty ())
local Data = setmetatable ({}, empty ())

-- This whole module uses the proxy pattern to hide data.
-- All objects returned to the caller are proxies,
-- and the corresponding real data is stored in the `hidden` table.
local hidden = setmetatable ({}, { __mode = "k" })

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

-- The mapping between types and their names:
defaults.types = {}

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
  hidden [module] = {}
  if _G.newproxy then
    local proxy = _G.newproxy (true)
    getmetatable (proxy).__gc = function ()
      M.__gc (module)
    end
    alive [module] = proxy
  end
  local m = hidden [module]
  -- Fill module with options or defaults:
  for key, default in pairs (defaults) do
    assert (options [key] == nil or type_of (options [key]) == type_of (default))
    m [key] = options [key] or default
  end
  -- Unique table for data and subdata:
  m.unique = setmetatable ({}, { __mode = "v" })
  -- Set of updated data:
  m.updated = {}
  -- Redis connection:
  m.redis = Redis:new ()
  m.redis:set_timeout (m.timeout)
  assert (m.redis:connect (m.host, m.port))
  return module
end

-- Destroy an instance of the module when it is no longer used:
function M.__gc (module)
  assert (getmetatable (module) == M)
  local m = hidden [module]
  -- It also cancels the changes that have been done,
  -- as the redis connection can be reused.
  -- Cancel the transaction:
  m.redis:discard ()
  -- Release redis connection
  assert (m.redis:set_keepalive (m.idle, m.pool))
  -- TODO: check if `assert` in `__gc` creates no problem.
end

-- Commit the changes:
function M.commit (module)
  assert (getmetatable (module) == M)
  local m = hidden [module]
  m.redis:multi ()
  -- Set all updated entities:
  for data, value in pairs (m.updated) do
    if value == ngx.null then
      -- Delete from redis:
      assert (m.redis:del (data.__identifier))
    else
      assert (m.redis:set (data.__identifier, m.encode_value (data.__contents)))
    end
  end
  -- Clear updated entities:
  m.updated = {}
  -- Commit changes to redis:
  assert (m.redis:exec ())
  -- FIXME: If the assertion fails, then the whole module instance is
  -- in a non consistent state, because data has been changed and is invalid
  -- for Redis. The assertion should not be recovered, except at the topmost
  -- level, where a new module instance is created, and the whole query
  -- performed again.
  return true
end

-- Create an object:
function M.create (module, type, contents)
  assert (type_of (contents) == "table")
  local m = hidden [module]
  -- Generate a key for the new data:
  local key = m.encode_key (m.redis:incr (m.identifiers))
  -- Insert data into redis:
  assert (m.redis:set (key, m.encode_value {
    __identifier = key,
    __type       = tostring (type),
    __contents   = {},
  }))
  -- Initialize the data:
  local object = module [key]
  getmetatable (object).__create (object, contents)
  return object
end

-- Delete an object:
function M.delete (module, object)
  if object == nil then
    return
  end
  local m = hidden [module]
  local d = hidden [object]
  -- Call the destructor of data:
  getmetatable (object).__delete (object)
  -- Delete from unique table:
  -- `ngx.null` marks it as to delete from redis
  m.unique [d.identifier] = ngx.null
  return true
end

-- Get an object:
function M.__index (module, key)
  assert (getmetatable (module) == M)
  -- If the key refers to a method, return it:
  if M [key] then
    return M [key]
  end
  -- Else, the key refers to an object that can exist or be missing:
  local m = hidden [module]
  -- If the key is an object, get its identifier:
  if hidden [key] then
    key = key.__identifier
  end
  -- If this object has already been loaded, return it:
  if m.unique [key] and m.unique [key] == ngx.null then
    return nil
  elseif m.unique [key] then
    return m.unique [key]
  end
  -- Load the object from redis,
  -- and watch its key to detect changes if needed:
  m.redis:watch (key)
  local data = m.redis:get (key)
  if data == ngx.null then
    return nil
  end
  data = m.decode_value (data)
  -- Load the object:
  local type   = m.types [data.__type]
  local object = type.__load (data)
  m.unique [key] = object
  return object
end

-- Update an object:
function M.__newindex (module, key, value)
  assert (getmetatable (module) == M)
  local m = hidden [module]
  -- If the key is an object, get its identifier:
  local previous
  if getmetatable (key) then
    previous = key
    key      = key.__identifier
  else
    previous = module [key]
  end
  -- In all cases, delete the previous object:
  M.delete (previous)
  m.updated [previous] = true
  -- If the value is not nil, replace object:
  if value then
    assert (getmetatable (value))
    -- Clone object:
    local type     = getmetatable (value)
    local contents = value.__contents
    local object   = type.__load (m.decode_value (m.encode_value (contents)))
    object.__identifier = key
    -- Set as updated:
    m.unique  [key   ] = object
    m.updated [object] = true
  end
end

-- Create a proxy over a type:
-- It forwards everything to the type,
-- but forbids overwriting the __index, __newindex and __call metamethods,
-- because they need to be implemented by this library.
local function proxy_of_type (type)
  local mt = {}
  mt.__call = function (...)
    return type (...)
  end
  mt.__tostring = function (_)
    return tostring (type)
  end
  mt.__index = function (_, key)
    return type [key]
  end
  mt.__newindex = function (_, key, value)
    assert (key ~= "__index"
        and key ~= "__newindex"
        and key ~= "__call")
    type [key] = value
  end
  return setmetatable ({}, mt)
end

-- The encoded object contains the following fields:
-- * __identifier: its unique identifier;
-- * __type: the name of its type;
-- * __contents: its contents.
-- Create a type:
function M.type (module, name)
  assert (getmetatable (module) == M)
  assert (type_of (name) == "string")
  local type = setmetatable ({}, {
    __call     = function (t, contents)
      return M.create (module, t, contents)
    end,
    __tostring = function (_)
      return name
    end,
  })
  local proxy  = proxy_of_type (type)
  local unique = setmetatable ({}, { __mode = "v" })
  -- Store type in module:
  local m = hidden [module]
  m.types [name] = proxy
  -- Define metamethods:
  type.__metatable = proxy
  type.__create = function (instance, contents)
    for key, value in pairs (contents) do
      instance [key] = value
    end
  end
  type.__delete = function (instance)
    local _ = instance
  end
  type.__load = function (x)
    assert (tostring (type) == x.__type)
    return setmetatable (x, type)
  end
  type.__index = function (instance, key)
    -- If the key refers to a method, return it directly:
    if type [key] then
      return type [key]
    end
    -- If the key starts with "__", rawget it:
    if type_of (key) == "string" and key:match "^__" then
      return rawget (instance, key)
    end
    -- Past this line, the key should be searched within contents.
    -- If the key refers to an object, obtain its identifier:
    if getmetatable (key) and not key.__current then
      key = "__" .. key.__identifier
    end
    -- Get the current location within the object:
    local current = instance.__current
                 or instance.__contents
    assert (type_of (current) == "table")
    current = current [key]
    -- If there is not subdata, return nil:
    if current == nil then
      return nil
    end
    -- Else, search for a unique representation:
    if unique [current] then
      return unique [current]
    end
    -- If the obtained value is a reference to an object, convert it:
    if type_of (current) == "string" and current:match "^__" then
      local identifier = current:match "^__(.*)$"
      return module [identifier]
    end
    -- If it is a subdata, compute it:
    local result = setmetatable ({
      __identifier = instance.__identifier,
      __type       = instance.__type,
      __contents   = instance.__contents,
      __current    = current,
    }, type)
    unique [current] = result
    return result
  end
  type.__newindex = function (instance, key, value)
    -- The key must not refer to a method:
    assert (not type [key])
    -- If the key starts with "__", rawget it:
    if type_of (key) == "string" and key:match "^__" then
      rawset (instance, key, value)
    end
    -- If the key refers to an object, obtain its identifier:
    if getmetatable (key) and not key.__current then
      key = "__" .. key.__identifier
    end
    -- If the value refers to an object, obtain its identifier:
    if getmetatable (value) and not value.__current then
      value = "__" .. value.__identifier
    end
    -- Update the value:
    -- Thanks to unique table, the change should be correctly propagated
    -- to other references.
    instance.__current [key] = value
    -- Mark as updated:
    local root = module [instance.__identifier]
    module.updated [root] = true
  end
  return proxy
end

return M
