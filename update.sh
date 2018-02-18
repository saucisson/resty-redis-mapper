#! /usr/bin/env sh

cd /tmp/sources

echo "Waiting for changes..."
while inotifywait \
  --recursive \
  --quiet \
  /tmp/sources
do
  luacheck     src/
  resty_busted src/
  echo ""
done
