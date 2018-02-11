FROM alpine:edge

COPY . /tmp/sources
ARG RESTY_VERSION="1.13.6.1"
RUN apk add --no-cache --virtual .build-deps \
        build-base \
        curl \
        make \
        openssl-dev \
        pcre-dev \
        perl \
        py-pip \
        readline-dev \
        unzip \
        zlib-dev \
 && apk add --no-cache \
        bash \
        openssl \
        pcre \
        readline \
 && pip install hererocks \
 && hererocks --luajit=2.0 \
              --luarocks=^ \
              --compat=5.2 \
              /usr \
 && luarocks install luasec \
 && cd /tmp \
 && curl -fSL https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz \
         -o openresty-${RESTY_VERSION}.tar.gz \
 && tar xzf openresty-${RESTY_VERSION}.tar.gz \
 && cd /tmp/openresty-${RESTY_VERSION} \
 && ./configure --with-ipv6 \
                --with-pcre-jit \
                --with-threads \
                --with-luajit=/usr \
                --prefix=/usr \
 && make \
 && make install \
 && rm -rf openresty-${RESTY_VERSION}.tar.gz openresty-${RESTY_VERSION} \
 && ln -sf /dev/stdout \
           /usr/nginx/logs/access.log \
 && ln -sf /dev/stderr \
           /usr/nginx/logs/error.log \
 && cp /tmp/sources/mime.types \
       /usr/nginx/conf/mime.types \
 && addgroup -g 82 -S www-data \
 && adduser  -u 82 -D -S -G www-data www-data \
 && apk del .build-deps \
 && rm -rf /tmp/* \
 && true

ENV PATH /usr/nginx/bin/:/usr/nginx/sbin/:$PATH
ENTRYPOINT ["nginx"]
CMD        ["-p", \
            "/usr/nginx/", \
            "-c", \
            "/tmp/sources/nginx.conf"]

COPY . /tmp/sources
RUN apk add --no-cache --virtual .build-deps \
        build-base \
        git \
        make \
 && apk add --no-cache \
        libgcc \
 && cd /tmp/sources \
 && luarocks make --only-deps resty-redis-mapper-master-0.rockspec \
 && ln -s /tmp/sources/src \
          /usr/share/lua/5.1/resty-redis-mapper \
 && cd / \
 && apk del .build-deps \
 && rm -rf /tmp/* \
 && true

VOLUME ["/tmp/sources"]
EXPOSE 80 443
