[![Build Status](https://travis-ci.org/saucisson/resty-redis-mapper.svg?branch=master)](https://travis-ci.org/saucisson/resty-redis-mapper)

# lua-redis-mapper

This module is an ORM reduced to its most simple expression.
It allows us to define data types (with no inheritance, only distinct types),
and objects (each one having exactly one data type).
Objects are automatically mapped into a Redis database.

## Install

This module is available as a Lua rock,
and can thus easily be installed using the following command:
```sh
$ luarocks install resty-redis-mapper
```

As it targets [OpenResty](https://openresty.org),
this module is only tested against [Luajit](http://luajit.org).

## API

The example code below shows the features provided by `resty-redis-mapper`:
```lua
-- Import the module:
local Rrm = require "resty-redis-mapper"

-- Instantiate the module with a specific configuration:
local rrm = Rrm {
  host = "redis",
  port = 6379,
}
-- There are some other configuration fields.

-- Create a data type named "type":
local Type = rrm / "type"
-- The type name defines the type of objects.
-- It must be unique within the application.

-- Feel free to add any method to the type,
-- but do **not** change `__index` and `__newindex`,
-- as they are implemented by `resty-redis-mapper`.
function Type:do_something ()
  self.value = 42
end
-- A default `__tostring` is defined, but it can be overwritten safely:
function Type:__tostring ()
  return tostring (self.value)
end

-- Create an object of type `Type`,
-- and get its unique identifier as second result:
local object, id_object  = Type {}

-- Update the object as a standard Lua table,
-- even creating references to objects within:
object.myself = object
object.t      = {
  a = 1,
  b = true,
}
object:do_something ()
assert (tostring (object) == "42", tostring (object))
-- Warning: all data put within a table is copied,
-- except references to objects.
-- This differs from the semantics of tables in the Lua language.

-- Commit all changes done since the module instantiation:
rrm ()
-- If the commit fails, an error is throws.
-- There is thus no need to wrap commit within an `assert`.

-- The module instance becomes unusable after commit,
-- in order to prevent inconsistencies:
assert (not pcall (function ()
  local _ = Type {}
end))

-- If you need to perform other changes,
-- create a new instance of the module.
rrm = Rrm { host = "redis", port = 6379 }

-- The type must be registered again,
-- because it is defined per instance of the module:
Type = rrm / "type"
-- This statement does not load the methods defined earlier.
-- In practice, users can create a function that registers all types,
-- and their associated methods.

-- And the object previously created can be loaded using its identifier:
object = rrm [id_object]
assert (object.myself == object)
assert (object.t.a == 1)
assert (object.t.b == true)

-- `resty-redis-mapper` uses transactions.
-- If an object has been modified by something else
-- between its loading and commit time, the commit fails:
object.c = "c"
do
  local o_rrm = Rrm { host = "redis", port = 6379 }
  local _ = o_rrm / "type"
  local o_object = o_rrm [id_object]
  o_object.c = nil
  o_rrm ()
end
-- This following commit fails,
-- because the object has been modified in the block above.
-- The local copy is thus in a inconsistent state with the reference.
rrm ()
-- Each commit is transactional:
-- either everything is updated, or nothing.

-- `resty-redis-mapper` allows to concurrently read objects.
-- There can also be one write to an object, that is read.
rrm      = Rrm { host = "redis", port = 6379 }
Type     = rrm / "type"
object   = rrm [id_object]
object.c = "c"
do
  local o_rrm = Rrm { host = "redis", port = 6379 }
  local _ = o_rrm / "type"
  local _ = o_rrm [id_object]
  o_rrm ()
end
-- This following commit is successful,
-- because the object has been modified by only one instance
-- of the module.
rrm ()

-- It is possible to delete an object using the usual Lua notation:
rrm    = Rrm { host = "redis", port = 6379 }
Type   = rrm / "type"
object = rrm [id_object]
rrm [object] = nil
-- rrm [id_object] = nil works as well
rrm ()
```
