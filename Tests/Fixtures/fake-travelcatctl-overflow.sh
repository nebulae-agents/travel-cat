#!/bin/zsh
trap '' TERM INT
(
  trap '' TERM INT
  /bin/sleep 0.05
  exec /usr/bin/yes 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
) &
print $! > "$TRAVEL_CAT_DATA/grandchild.pid"
wait
