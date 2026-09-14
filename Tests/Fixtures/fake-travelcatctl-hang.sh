#!/bin/zsh
trap '' TERM INT
(
  trap '' TERM INT
  while true; do :; done
) &
print $! > "$TRAVEL_CAT_DATA/grandchild.pid"
while true; do :; done
