FROM openresty/openresty:alpine-fat

COPY . /tmp/sources

RUN true \
 && apk add --no-cache --virtual .build-deps \
        build-base \
        git \
        make \
 && apk add --no-cache \
        inotify-tools \
        libgcc \
 && cd /tmp/sources \
 && luarocks install luacheck \
 && luarocks install https://raw.githubusercontent.com/saucisson/lua-resty-busted/master/lua-resty-busted-master-0.rockspec \
 && luarocks install --only-deps resty-redis-mapper-master-0.rockspec \
 && cd / \
 && apk del .build-deps \
 && rm -rf /tmp/* \
 && true

VOLUME ["/tmp/sources"]
