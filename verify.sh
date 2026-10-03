#!/usr/bin/env bash
# Runtime self-check for the nested Caelestia session.
#
# Every one of the nine breakages found while building this thing presented as
# a working system quietly doing nothing - no crash, no non-zero exit, just a
# feature that was not there. A rebuild can therefore pass and still be broken.
# This asserts the things that actually matter, against the running container,
# in a couple of seconds.
#
#   ./verify.sh              # check the container named caelestia
#   ./verify.sh mycontainer
#
# Exit code is 0 only if every check passes.

set -uo pipefail

CONTAINER="${1:-caelestia}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi

pass=0; fail=0; skip=0
declare -a FAILED

ok()   { pass=$((pass+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
no()   { fail=$((fail+1)); FAILED+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
warn() { skip=$((skip+1)); printf '  %sSKIP%s  %s\n' "$Y" "$N" "$1"; }
head_() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# run a command inside the container as the ubuntu user in the nested env
asuser() { docker exec -u ubuntu -e HOME=/home/ubuntu -e XDG_RUNTIME_DIR=/run/user/1000 "$CONTAINER" bash -lc "$1" 2>/dev/null; }
asroot(){ docker exec "$CONTAINER" bash -lc "$1" 2>/dev/null; }

printf '%s=== nested Caelestia verification: %s ===%s\n' "$B" "$CONTAINER" "$N"

# --------------------------------------------------------------- container
head_ "container"
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then
  ok "container is running"
else
  no "container is running" "docker inspect says it is not. Run ./build-image.sh"
  printf '\n%s%d passed, %d failed%s\n' "$B" "$pass" "$fail" "$N"; exit 1
fi

AA=$(docker inspect -f '{{.AppArmorProfile}}' "$CONTAINER" 2>/dev/null)
if [ "$AA" = "unconfined" ]; then ok "AppArmor profile is unconfined"
else no "AppArmor profile is unconfined" "got '$AA'. Without this the shell silently loses MPRIS, tray and notifications. Re-run ./build-image.sh"; fi

# `id -G ubuntu` looks the user up in /etc/group and CANNOT show --group-add 990,
# because the image has no group file entry for that gid. Only the live process's
# own supplementary groups carry it.
GIDS=$(asuser 'id -G')
for g in 44 990; do
  if echo "$GIDS" | tr ' ' '\n' | grep -qx "$g"; then ok "supplementary GID $g present ($([ $g = 44 ] && echo video || echo render))"
  else no "supplementary GID $g present" "uid 1000 cannot open /dev/dri/renderD128 without it; aquamarine dies with CBackend::create() failed!"; fi
done

# --------------------------------------------------------------------- gpu
head_ "gpu"
if docker exec "$CONTAINER" sh -c 'command -v eglinfo >/dev/null || apt-get install -y -qq --no-install-recommends mesa-utils libegl1 >/dev/null 2>&1' 2>/dev/null; then
  REND=$(asroot 'eglinfo -B 2>/dev/null | grep -m1 "core profile renderer"' | sed 's/.*renderer: //')
  case "$REND" in
    *llvmpipe*|"") no "hardware GPU rendering" "renderer='${REND:-unknown}'. Needs --cap-add SYS_ADMIN and --device /dev/dri" ;;
    *) ok "hardware GPU rendering: $REND" ;;
  esac
else
  warn "gpu renderer (eglinfo unavailable)"
fi
if asroot 'head -c 0 /dev/dri/renderD128' >/dev/null 2>&1; then
  ok "render node openable by root in the container"
else
  no "render node openable by root in the container"
fi
if asuser 'head -c 0 /dev/dri/renderD128' >/dev/null 2>&1; then
  ok "render node openable by uid 1000 (the compositor's user)"
else
  no "render node openable by uid 1000" "needs --group-add 990; without it aquamarine cannot create a GBM allocator"
fi

# ----------------------------------------------------------------- sockets
head_ "host session binding"
SOCKS=$(asroot 'ls /run/user/1000/wayland-0 /run/user/1000/bus 2>/dev/null' | wc -l)
[ "$SOCKS" -ge 2 ] && ok "host Wayland + D-Bus sockets visible in /run/user/1000" \
                  || no "host Wayland + D-Bus sockets visible in /run/user/1000" "needs -v /run/user/1000:/run/user/1000"
if asroot 'command -v wayland-info >/dev/null'; then
  asuser 'wayland-info 2>/dev/null | grep -q "wl_compositor"' && ok "outer compositor answers (wl_compositor)" \
                                                    || no "outer compositor answers (wl_compositor)"
else
  warn "wayland-info not installed"
fi

# -------------------------------------------------------------- compositor
head_ "nested compositor"
procs() { asroot "ps -eo pid,stat,args --no-headers | grep -Ev '^ *[0-9]+ +Z' | grep -E '$1' | grep -v grep"; }
nh=$(procs 'hyprland' | wc -l)
[ "$nh" -eq 2 ] && ok "exactly one hyprland (2 procs: parent + child)" \
                || no "exactly one hyprland (2 procs)" "found $nh. hyprland is two processes; extra pairs mean leaked instances"
ns=$(procs 'caelestia-shell-supervisor' | wc -l)
[ "$ns" -eq 2 ] && ok "exactly one shell supervisor" \
                || no "exactly one shell supervisor" "found $ns. Leaked loops sum their exclusive zones - see reserved below"
nq=$(procs 'qs -c caelestia' | wc -l)
[ "$nq" -eq 1 ] && ok "exactly one qs -c caelestia" \
                || no "exactly one qs -c caelestia" "found $nq"

SIG=$(asroot 'ls -1dt /run/user/1000/hypr/*/ 2>/dev/null | head -1 | xargs basename 2>/dev/null')
if [ -n "$SIG" ]; then
  ok "instance signature: $SIG"
  H() { docker exec -e HYPRLAND_INSTANCE_SIGNATURE="$SIG" "$CONTAINER" bash -lc "hyprctl $1" 2>/dev/null; }
  MON=$(H monitors)
  # With zero outputs Hyprland answers `monitors` with "unknown request" and
  # activeworkspace reports monitor FALLBACK, so probe the workspace too.
  AW=$(H activeworkspace)
  if echo "$MON" | grep -q 'WAYLAND-1'; then
    ok "monitor is the nested output (WAYLAND-1)"
  elif echo "$AW" | grep -qi 'FALLBACK'; then
    no "monitor is the nested output (WAYLAND-1)" "the outer compositor withdrew the wl_output (FALLBACK). Closing the host window, or the host display sleeping, destroys the surface. Run ./cleanup.sh then ./start.sh"
  else
    no "monitor is the nested output (WAYLAND-1)" "hyprctl monitors said '$(echo "$MON" | head -1)'"
  fi

  RES=$(echo "$MON" | grep -m1 'reserved:' | awk '{print $2}')
  if echo "$MON" | grep -q 'WAYLAND-1'; then
    if [ "$RES" = "60" ]; then ok "exclusive zone reserved: 60 (single shell instance)"
    elif [ -n "$RES" ] && [ "$RES" -gt 0 ] && [ $((RES % 60)) -eq 0 ]; then
      no "exclusive zone reserved: 60" "got $RES = $((RES/60)) x 60. Leaked supervisor loops. Run ./cleanup.sh before ./start.sh"
    else
      warn "reserved='${RES:-none}' (60 expected once the shell registers)"
    fi
    SC=$(echo "$MON" | grep -m1 'scale:' | awk '{print $2}')
    if [ "$SC" = "1.00" ]; then ok "scale pinned to 1.00"
    else no "scale pinned to 1.00" "got $SC. 'auto' picks 2.0 on a HiDPI panel and halves the desktop"; fi
  else
    warn "exclusive zone / scale (no output to measure)"
  fi
  H layers | grep -q 'caelestia-drawers' && ok "shell layer surfaces present (compositing)" \
                                          || no "shell layer surfaces present (compositing)"
else
  no "instance signature found" "no /run/user/1000/hypr/*/ directory. Run ./start.sh"
fi

# ------------------------------------------------------------------- shell
head_ "caelestia shell"
if asroot 'test -e /usr/lib/x86_64-linux-gnu/qt6/qml/Caelestia/libcaelestia-coreplugin.so'; then
  ok "Caelestia QML module on Qt's import path"
else
  no "Caelestia QML module on Qt's import path" "Qt searches only /usr/lib/x86_64-linux-gnu/qt6/qml. Without the symlink: module \"Caelestia.Config\" is not installed"
fi
if asroot 'test -e /usr/lib/x86_64-linux-gnu/qt6/qml/M3Shapes'; then
  ok "M3Shapes QML module present"
else
  no "M3Shapes QML module present"
fi

LOG="/tmp/caelestia-shell-${SIG:-nosig}.log"
if asroot "test -f '$LOG'"; then
  if asroot "grep -qa 'Configuration Loaded' '$LOG'"; then
    ok "shell log reports 'Configuration Loaded'"
  else
    no "shell log reports 'Configuration Loaded'" "$(asroot "grep -aiE 'error|not installed|not a type' '$LOG' | sort -u | head -3")"
  fi
  if asroot "grep -aq 'Unknown option' '$LOG'"; then
    no "shell.json schema clean (no unknown keys)" "$(asroot "grep -a 'Unknown option' '$LOG' | sort -u | head -3")"
  else ok "shell.json schema clean (no unknown keys)"; fi
  # bluetooth / upower / powerprofiles resolve on the host's SYSTEM bus, which a
  # container has no socket for. Expected noise, so a warning rather than a
  # failure. mpris / notifications / StatusNotifier are the session-bus services
  # that must work, and they are gated separately below.
  dbfail=$(asroot "grep -a 'Could not connect to DBus' '$LOG' | sort -u")
  if [ -n "$dbfail" ]; then
    sess=$(printf '%s\n' "$dbfail" | grep -oiE 'mpris|notifications|sni\.[a-z]+|hyprland' | sort -u | tr '\n' ' ')
    if [ -n "$sess" ]; then
      no "session-bus services connected" "these need the session bus: $sess"
    else
      sysd=$(printf '%s\n' "$dbfail" | grep -oiE 'bluetooth|upower|powerprofiles|sessionmanager' | sort -u | tr '\n' ' ')
      warn "host system-bus services unavailable (expected in a container)" "$sysd"
    fi
  else
    ok "no D-Bus connection failures"
  fi
else
  no "shell log found at $LOG" "the supervisor may not have started"
fi

# -------------------------------------------------------------------- dbus
head_ "host integration (dbus)"
BUSADDR='unix:path=/run/user/1000/bus'
NB=$(docker exec -u ubuntu -e HOME=/home/ubuntu -e XDG_RUNTIME_DIR=/run/user/1000 \
      -e DBUS_SESSION_BUS_ADDRESS="$BUSADDR" "$CONTAINER" \
      bash -lc 'busctl --user list 2>/dev/null | grep -c .' 2>/dev/null)
if [ "${NB:-0}" -gt 10 ]; then ok "session bus reachable ($NB names visible)"
else no "session bus reachable" "busctl saw ${NB:-0} names. AppArmor is blocking D-Bus - recreate with --security-opt apparmor=unconfined"; fi
MP=$(docker exec -u ubuntu -e HOME=/home/ubuntu -e XDG_RUNTIME_DIR=/run/user/1000 \
      -e DBUS_SESSION_BUS_ADDRESS="$BUSADDR" "$CONTAINER" \
      bash -lc 'busctl --user list 2>/dev/null | grep -ci mpris' 2>/dev/null)
if [ "${MP:-0}" -gt 0 ]; then ok "MPRIS player visible from the container ($MP)"
else warn "no MPRIS player on the bus (nothing playing on the host?)"; fi

# ------------------------------------------------------------------- fonts
head_ "fonts"
FONTS=("Material Symbols Rounded" "Rubik" "CaskaydiaCove NF" "Noto Sans CJK JP" "Noto Sans CJK SC" "Noto Sans CJK TC" "Noto Sans CJK KR")
bad=()
for f in "${FONTS[@]}"; do
  m=$(asuser "fc-match '$f' 2>/dev/null")
  case "$m" in *NotoSans-Regular*|*DejaVuSans*|"") bad+=("$f") ;;
  esac
done
if [ ${#bad[@]} -eq 0 ]; then
  ok "all ${#FONTS[@]} font families resolve (3 latin + 4 CJK)"
else
  no "all ${#FONTS[@]} font families resolve" "falling back to NotoSans/DejaVu: ${bad[*]}"
fi

# -------------------------------------------------------------------- done
printf '\n%s────────────────────────────────────────%s\n' "$B" "$N"
if [ "$fail" -eq 0 ]; then
  printf '%s%d passed%s' "$G" "$pass" "$N"
  [ "$skip" -gt 0 ] && printf ', %d skipped' "$skip"
  printf '\n'
  exit 0
else
  printf '%s%d passed, %d FAILED%s\n' "$R" "$pass" "$fail" "$N"
  for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
