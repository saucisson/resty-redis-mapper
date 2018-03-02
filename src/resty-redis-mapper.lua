-- luacheck: new globals ngx

local Coromake = require "coroutine.make"
local Hashids  = require "hashids"
local MsgPack  = require "cmsgpack"
local Redis    = require "resty.redis"
local Serpent  = require "serpent"

-- Create an empty metatable:
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

-- The prefixes for references and strings within objects:
defaults.reference_prefix = "@/"
defaults.string_prefix    = "*/"

-- The encoding function for unique identifiers:
local hashids = Hashids.new ("a default salt", 8)
defaults.encode_key = function (key)
  assert (type (key) == "number", key)
  return hashids:encode (key)
end

-- Get a reference to an object or an identifier:
local function reference_of (module, object)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  if type (object) == "table" then
    local identifier = m.metadata [object].identifier
    return reference_of (module, identifier)
  end
  assert (type (object) == "string")
  if not m.references [object] then
    local result = setmetatable ({}, m.Reference)
    m.references [object] = result
    m.targets    [result] = object
  end
  return m.references [object]
end

-- The encoding and decoding functions for data:
defaults.encode_value = function (module, object)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  local function convert (t)
    if m.targets [t] then
      return defaults.reference_prefix .. m.targets [t]
    elseif type (t) == "table" then
      local result = {}
      for key, value in pairs (t) do
        key   = convert (key)
        value = convert (value)
        result [key] = value
      end
      return result
    elseif type (t) == "number"
        or type (t) == "boolean" then
      return t
    elseif type (t) == "string" then
      return defaults.string_prefix .. t
    else
      assert (false)
    end
  end
  return MsgPack.pack (convert {
    metadata = assert (m.metadata [object]),
    contents = assert (m.contents [object]),
  })
end
defaults.decode_value = function (module, string)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  if string == ngx.null then
    return nil
  end
  local function convert (t)
    if type (t) == "table" then
      local result = {}
      for key, value in pairs (t) do
        key   = convert (key)
        value = convert (value)
        result [key] = value
      end
      return result
    elseif type (t) == "number"
        or type (t) == "boolean" then
      return t
    elseif type (t) == "string"
       and t:match ("^" .. defaults.reference_prefix) then
      local key = t:match ("^" .. defaults.reference_prefix .. "(.*)$")
      return reference_of (module, key)
    elseif type (t) == "string"
       and t:match ("^" .. defaults.string_prefix) then
      return t:match ("^" .. defaults.string_prefix .. "(.*)$")
    else
      assert (false)
    end
  end
  return convert (MsgPack.unpack (string))
end

-- Create a new instance of the module:
getmetatable (M).__call = function (_, options)
  assert (options == nil or type (options) == "table")
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
    assert (options [key] == nil or type (options [key]) == type (default))
    m [key] = options [key] or default
  end
  -- Metatable for references:
  m.Reference = setmetatable ({}, empty ())
  -- Inconsistent flag warns that the instance should not be used,
  -- because it has reached an inconsistent state with its objects:
  m.consistent = true
  -- Unique table for data and subdata:
  m.objects    = setmetatable ({}, { __mode = "v" }) -- key    -> object
  m.metadata   = setmetatable ({}, { __mode = "k" }) -- object -> info
  m.contents   = setmetatable ({}, { __mode = "k" }) -- object -> data
  -- Unique table for references:
  m.references = setmetatable ({}, { __mode = "v" }) -- key    -> ref
  m.targets    = setmetatable ({}, { __mode = "k" }) -- ref    -> key
  -- Set of updated data:
  m.updated = {}
  -- Types:
  m.metas = setmetatable ({}, { __mode = "v" }) -- key -> type
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

-- Get an object:
function M.__index (module, key)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
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
  data = m.decode_value (module, data)
  -- Load the object:
  local meta   = m.metas [data.metadata.meta]
  local object = meta (data.contents, data.metadata.identifier)
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
  local previous = module [key]
  -- Delete from unique table:
  -- `ngx.null` marks it as to delete from redis
  m.objects [key     ] = ngx.null
  m.updated [previous] = true
  -- If the value is not nil, replace object:
  if value ~= nil then
    -- Clone object:
    local meta   = assert (getmetatable (value))
    local object = meta ({}, m.metadata [value].identifier)
    m.contents [object] = m.decode_value (m.encode_value (m.contents [value]))
    m.updated  [object] = true
  end
end

function M.__call (module)
  return M.commit (module)
end

function M.__div (module, type_name)
  return M.type (module, type_name)
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
      assert (m.redis:set (identifier, m.encode_value (module, data)))
    end
  end
  -- Clear updated entities:
  m.updated = {}
  -- Commit changes to redis:
  m.consistent = false
  local ok, err = m.redis:exec ()
  -- If the assertion fails, then the whole module instance is
  -- in a non consistent state, because data has been changed and is invalid
  -- for Redis. The assertion should not be recovered, except at the topmost
  -- level, where a new module instance is created, and the whole query
  -- performed again.
  -- In all cases, cleanup:
  M.__gc (module)
  assert (ok, err)
  return true
end

-- Create a type:
function M.type (module, name)
  assert (getmetatable (module) == M)
  local m = modules [module]
  assert (m.consistent)
  assert (type (name) == "string")
  -- Metatable for subdata:
  local table = {}
  -- Metatable for type:
  local meta  = setmetatable ({}, {
    __call = function (t, contents, identifier)
      assert (m.consistent)
      -- Generate a key for the new data if needed:
      identifier = identifier
                or m.encode_key (m.redis:incr (m.identifiers))
      -- Create object and fill its contents:
      local instance = setmetatable ({}, t)
      m.metadata [instance] = {
        identifier = identifier,
        meta       = tostring (t),
      }
      m.contents [instance  ] = contents
      m.objects  [identifier] = instance
      m.updated  [instance  ] = true
      return instance, identifier
    end,
    __tostring = function (_)
      return name
    end,
  })
  -- Store type in module:
  m.metas [name] = meta
  -- Define the `__tostring` metamethod:
  meta.__tostring = function (instance)
    assert (m.consistent)
    local metadata = m.metadata [instance]
    local data     = m.contents [instance]
    return meta.identifier
        .. " : "
        .. metadata.meta
        .. " = "
        .. Serpent.block (data)
  end

  -- Unique table for subdata:
  local subdata = setmetatable ({}, { __mode = "v" })
  local unique  = setmetatable ({}, { __mode = "v" })
  local function convert (t)
    if t == nil then
      return nil
    elseif m.metadata [t] then
      return reference_of (module, t)
    elseif m.targets [t] then
      return t
    elseif type (t) == "table" then
      local result = {}
      for key, value in pairs (t) do
        key   = convert (key)
        value = convert (value)
        result [key] = value
      end
      return result
    elseif type (t) == "number"
        or type (t) == "boolean"
        or type (t) == "string" then
      return t
    else
      assert (false, type (t))
    end
  end
  meta.__index = function (instance, key)
    assert (m.consistent)
    assert (m.metadata [instance] or subdata [instance])
    -- If the key refers to an object, convert it into a reference:
    key = convert (key)
    -- Get the current location within the object:
    local current = m.contents [instance]
                 or subdata [instance].contents
    assert (type (current) == "table")
    current = current [key]
    -- If there is not subdata, search in the type:
    if current == nil then
      -- If in an object and the key refers to a method, return it directly:
      if m.metadata [instance] then
        return meta [key]
      else
        return nil
      end
    end
    -- If the obtained value is a reference to an object, load it:
    if m.targets [current] then
      local identifier = m.targets [current]
      return module [identifier]
    end
    if type (current) ~= "table" then
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
  meta.__newindex = function (instance, key, value)
    assert (m.consistent)
    assert (m.metadata [instance] or subdata [instance])
    assert (not subdata [key] and not subdata [value])
    -- If key or value are objects, get references to them:
    key   = convert (key)
    value = convert (value)
    -- Get the current location within the object:
    local current = m.contents [instance]
                 or subdata [instance].contents
    assert (type (current) == "table")
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
  -- The __len operator is a proxy over the raw data:
  meta.__len = function (instance)
    assert (m.consistent)
    assert (m.metadata [instance] or subdata [instance])
    if m.metadata [instance] then
      return #m.contents [instance]
    elseif subdata [instance] then
      return #subdata [instance]
    end
  end
  -- The __ipairs operator is a proxy over the raw data:
  meta.__ipairs = function (instance)
    assert (m.consistent)
    assert (m.metadata [instance] or subdata [instance])
    local coroutine = Coromake ()
    return coroutine.wrap (function ()
      for i in ipairs (m.contents [instance] or subdata [instance]) do
        coroutine.yield (i, instance [i])
      end
    end)
  end
  -- The __pairs operator is a proxy over the raw data:
  meta.__pairs = function (instance)
    assert (m.consistent)
    assert (m.metadata [instance] or subdata [instance])
    local coroutine = Coromake ()
    return coroutine.wrap (function ()
      for k in pairs (m.contents [instance] or subdata [instance]) do
        coroutine.yield (k, instance [k])
      end
    end)
  end
  table.__index    = meta.__index
  table.__newindex = meta.__newindex
  table.__len      = meta.__len
  table.__ipairs   = meta.__ipairs
  table.__pairs    = meta.__pairs
  return meta
end

return M
