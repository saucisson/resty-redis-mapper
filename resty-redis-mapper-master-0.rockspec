-- luacheck: std rockspec

package = "resty-redis-mapper"
version = "master-0"

source = {
  url    = "git+https://github.com/saucisson/resty-redis-mapper.git",
  branch = "master",
}

description = {
  summary    = "",
  detailed   = [[]],
  license    = "MIT/X11",
  homepage   = "https://github.com/saucisson/resty-redis-mapper",
  maintainer = "Alban Linard <alban@linard.fr>",
}

dependencies = {
  "lua >= 5.1",
  "coronest",
  "hashids",
  "lua-cmsgpack",
  "lua-resty-busted",
  "serpent",
}

build = {
  type    = "builtin",
  modules = {
    ["resty-redis-mapper"] = "src/init.lua",
  },
}
