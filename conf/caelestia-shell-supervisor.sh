#!/usr/bin/env bash
# Stand-in for caelestia-shell.service, which needs a systemd user manager that
# does not exist in this container.
#
# Upstream semantics reproduced: Restart=on-failure with
# StartLimitBurst=5 / StartLimitIntervalSec=300. A plain `while true` would
# instead spin forever on a genuinely broken config.
#
# What systemd provides for free and a shell loop does not: lifetime. Hyprland
# exec-once children are reparented to PID 1 and outlive the compositor, so an
# unguarded loop keeps spawning qs against a dead WAYLAND_DISPLAY. Three leaked
# loops once ran at once and their exclusive zones summed - Hyprland reported
# `reserved: 180 30 30 30` for a 60px bar.
#
# Liveness is read from Hyprland's own lock file, which holds the compositor
# PID on line 1 and its WAYLAND_DISPLAY on line 2. Checking that the socket
# *file* still exists is not enough: a SIGKILLed compositor leaves the socket
# inode behind and `-S` keeps returning true.
set -u

sig=${HYPRLAND_INSTANCE_SIGNATURE:-}
runtime=${XDG_RUNTIME_DIR:-/run/user/1000}
lock="$runtime/hypr/$sig/hyprland.lock"
LOG="/tmp/caelestia-shell-${sig:-nosig}.log"
BURST=5
WINDOW=300

if [ -z "$sig" ] || [ ! -r "$lock" ]; then
    printf '%s no usable %s, refusing to start\n' "$(date -Is)" "$lock" >&2
    exit 1
fi

hyprland_pid=$(sed -n 1p "$lock" | tr -cd '0-9')
if [ -z "$hyprland_pid" ]; then
    printf '%s %s has no pid on line 1\n' "$(date -Is)" "$lock" >&2
    exit 1
fi

alive() { kill -0 "$hyprland_pid" 2>/dev/null; }

count=0
window_start=$(date +%s)

while alive; do
    now=$(date +%s)
    if [ $((now - window_start)) -gt "$WINDOW" ]; then
        count=0
        window_start=$now
    fi
    count=$((count + 1))
    if [ "$count" -gt "$BURST" ]; then
        printf '%s burst limit reached (%d starts in %ss), giving up\n' \
            "$(date -Is)" "$count" "$WINDOW" >>"$LOG"
        exit 1
    fi

    printf '\n==== %s start #%d ====\n' "$(date -Is)" "$count" >>"$LOG"
    qs -c caelestia >>"$LOG" 2>&1
    rc=$?
    printf '%s qs exited rc=%s\n' "$(date -Is)" "$rc" >>"$LOG"

    [ "$rc" -eq 0 ] && exit 0
    alive || break
    sleep 2
done

printf '%s hyprland pid %s is gone, supervisor exiting\n' "$(date -Is)" "$hyprland_pid" >>"$LOG"
