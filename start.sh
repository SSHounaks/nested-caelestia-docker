#!/usr/bin/env bash
# Bring up the nested Hyprland + Caelestia shell inside the container.
# Run /tmp/cleanup.sh first: leftover supervisors and orphaned qs processes from
# a previous instance will happily run alongside this one.
set -eu

# The native daemon. Docker Desktop's VM cannot run this container - see
# section 2b of the build log.
export DOCKER_HOST=unix:///var/run/docker.sock

docker exec -d -u ubuntu \
  -e HOME=/home/ubuntu \
  -e XDG_RUNTIME_DIR=/run/user/1000 \
  -e WAYLAND_DISPLAY=wayland-0 \
  -e HYPRLAND_NO_CRASHREPORTER=1 \
  -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  caelestia bash -lc 'hyprland'

sleep 10
SIG=$(docker exec caelestia bash -c 'ls -1dt /run/user/1000/hypr/*/ | head -1 | xargs basename')
echo "HYPRLAND_INSTANCE_SIGNATURE=$SIG"
docker exec caelestia bash -c "HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl monitors" | sed -n '1,10p'
