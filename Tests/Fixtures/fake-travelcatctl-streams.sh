#!/bin/zsh
descriptor_path() {
  /usr/sbin/lsof -a -p $$ -d "$1" -Fn | /usr/bin/sed -n 's/^n//p'
}

stdin_path=$(descriptor_path 0)
test -n "$stdin_path" || exit 70
test "$(/usr/bin/stat -f %Lp "$stdin_path")" = 600 || exit 71
case "$stdin_path" in
  "$TRAVEL_CAT_DATA"/*) exit 72 ;;
esac
test "$(/usr/bin/stat -f %Lp "${stdin_path:h}")" = 700 || exit 73
test "$(/bin/cat)" = private-input || exit 74
/usr/bin/head -c 131072 /dev/zero | /usr/bin/tr '\0' O
/usr/bin/head -c 131072 /dev/zero | /usr/bin/tr '\0' E >&2
exit 65
