#! /usr/bin/env sh

cd /tmp/sources || exit 1

echo "Waiting for changes..."
last=$(date "+%s")
while inotifywait \
  --recursive \
  --quiet \
  /tmp/sources
do
  current=$(date "+%s")
  if [ $((current - last)) -ge 1 ]
  then
    luacheck src/
    resty_busted src/
    echo ""
  fi
done
