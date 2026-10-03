#!/usr/bin/env bash
# Kill every nested-session process. Uses exact-name matching on purpose:
# `pkill -f <pattern>` also matches the `docker exec` shell that carries the
# pattern in its own argv, so it kills the cleanup halfway through.
set -u
echo "before:"
ps -eo pid,stat,args --no-headers | grep -Ev '^ *[0-9]+ +Z' | grep -E 'qs -c|hyprland|supervisor' | cat

for p in $(pgrep -x qs); do kill -9 "$p" 2>/dev/null; done
for p in $(pgrep -f 'shell-super'); do [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null; done
sleep 1
for p in $(pgrep -x hyprland); do kill -9 "$p" 2>/dev/null; done
sleep 2

rm -f /run/user/1000/wayland-1 /run/user/1000/wayland-1.lock
rm -rf /run/user/1000/hypr/*/ /tmp/caelestia-shell*.log
rm -rf /home/ubuntu/.cache/quickshell/crashes

echo "after:"
ps -eo pid,stat,args --no-headers | grep -Ev '^ *[0-9]+ +Z' | grep -E 'qs -c|hyprland|supervisor' | cat
echo "(empty above means clean)"
