#!/usr/bin/env bash
# Build the nested Caelestia image and run it against the host's live GNOME
# session. See Dockerfile for what each layer is for.
#
# The container's device flags are the load-bearing part and cannot be baked
# into an image:
#
#   --cap-add SYS_ADMIN   aquamarine cannot open the render node without it,
#                         and falls back to llvmpipe (Phase 0, gate 3)
#   --group-add 44        video, for /dev/dri/card1
#   --group-add 990       render, for /dev/dri/renderD128 - note the numeric
#                         GID, `--group-add render` fails because the image has
#                         no group by that name
#   -v /run/user/1000     the host's Wayland socket AND its D-Bus socket. This
#                         bind is what gives the nested shell the host's tray,
#                         MPRIS player and notifications. It also means anything
#                         in the container can reach the live session.
set -euo pipefail

# D8/D22: the native daemon, never Docker Desktop's VM - that one has no
# /dev/dri and no /run/user/1000. Harmless if `docker context use default`
# is already set; kept explicit because it is self-documenting.
export DOCKER_HOST=unix:///var/run/docker.sock

cd "$(dirname "$0")"

echo "==> building caelestia-nested"
docker build -t caelestia-nested .

echo "==> replacing any previous container"
docker rm -f caelestia >/dev/null 2>&1 || true

echo "==> starting container"
docker run -d --name caelestia --init \
  --cap-add SYS_ADMIN \
  --device /dev/dri --group-add 44 --group-add 990 \
  -v /run/user/1000:/run/user/1000 \
  -e XDG_RUNTIME_DIR=/run/user/1000 \
  -e WAYLAND_DISPLAY=wayland-0 \
  caelestia-nested sleep infinity

echo "==> GPU gate (must NOT say llvmpipe)"
docker exec caelestia sh -c 'apt-get install -y -qq --no-install-recommends mesa-utils libegl1 >/dev/null 2>&1; eglinfo -B 2>/dev/null | grep -m1 "core profile renderer"'

echo "==> socket gate"
docker exec -u ubuntu -e HOME=/home/ubuntu -e XDG_RUNTIME_DIR=/run/user/1000 \
  -e WAYLAND_DISPLAY=wayland-0 caelestia sh -c 'command -v wayland-info >/dev/null || apt-get install -y -qq --no-install-recommends wayland-utils >/dev/null 2>&1; wayland-info | head -3'

echo
echo "Done. Now run: ./start.sh"
