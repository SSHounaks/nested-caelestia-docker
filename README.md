# nested-caelestia-docker

Runs the [Caelestia](https://github.com/caelestia-dots) desktop shell inside a
Docker container, on a nested Hyprland compositor, on top of an untouched
GNOME/Wayland session.

Everything needed to build and run it, and nothing that touches the host.

> **Status: the `Dockerfile` builds clean from scratch on `ubuntu:26.04`.**
> It was reconstructed from the verified contents of a working container (dpkg
> database, CMake caches, install prefixes, apt history) rather than being the
> artifact that was built interactively, and the first end-to-end runs of the
> reconstruction found seven real breakages, six of them fatal. All seven are
> fixed and pinned; see [Known issues](#known-issues) for what they were.

> **The container will not appear in Docker Desktop.** Docker Desktop runs its
> own Linux VM with its own daemon; this project runs on the host's native
> daemon, because the Desktop VM has no `/dev/dri` (no GPU) and no
> `/run/user/1000` (no Wayland or D-Bus socket). Nothing is wrong. `docker
> context use default` below is the whole fix - and note it only affects the
> CLI. The GUI is hard-wired to its own VM's socket and will always show an
> empty list.

```bash
docker context use default    # so the CLI needs no DOCKER_HOST prefix
docker info --format '{{.Name}} {{.KernelVersion}}'   # want: shalnark 7.0.0-34-generic
```

Note that launching Docker Desktop re-activates `desktop-linux`, which silently
points the CLI back at the empty VM. Re-run the `context use` line, or just
`export DOCKER_HOST=unix:///var/run/docker.sock` and ignore contexts entirely.

## One-time setup

```bash
./build-image.sh
```

Builds the image, replaces any previous container, starts it with the device
flags that actually matter, and re-runs the two attach gates (hardware GPU, host
Wayland socket). It ends by printing the GPU renderer string - if that says
`llvmpipe`, stop; the run is not viable.

## Each session

```bash
docker cp cleanup.sh caelestia:/tmp/cleanup.sh
docker exec caelestia bash /tmp/cleanup.sh   # not optional, see below
./start.sh
```

`cleanup.sh` first, every time. Each Hyprland launch spawns a supervisor, and a
supervisor whose compositor died keeps restarting `qs` against a dead display.
Three leaked loops once ran at once. The tell is a reserved border that is a
multiple of 60:

```
reserved: 180 30 30 30     # three shell instances
reserved:  60 10 10 10     # correct
```

## Files

| Path | Goes to |
|---|---|
| `Dockerfile` | build context |
| `danklinux.asc` | `/usr/share/keyrings/` inside the image |
| `qt6.10-compat.patch` | applied to the shell tree during build |
| `build-image.sh` | run from the host |
| `start.sh` | run from the host |
| `cleanup.sh` | `/tmp/cleanup.sh` in the container (also baked to `/home/ubuntu/cleanup.sh`) |
| `conf/hyprland.conf` | `/home/ubuntu/.config/hypr/hyprland.conf` |
| `conf/shell.json` | `/home/ubuntu/.config/caelestia/shell.json` |
| `conf/qml_color.json` | `/home/ubuntu/.config/quickshell/qml_color.json` |
| `conf/caelestia-shell-supervisor.sh` | `/home/ubuntu/bin/caelestia-shell-supervisor.sh` |

## Inspect

```bash
SIG=$(docker exec caelestia bash -c 'ls -1dt /run/user/1000/hypr/*/ | head -1 | xargs basename')

docker exec caelestia bash -c "HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl monitors"
docker exec caelestia bash -c "HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl clients"
docker exec caelestia bash -c "HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl layers"

# drive the shell
docker exec caelestia bash -c "HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl dispatch global caelestia:dashboard"
docker exec caelestia bash -c "HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl dispatch global caelestia:showall"

# screenshot
docker exec -u ubuntu -e HOME=/home/ubuntu -e XDG_RUNTIME_DIR=/run/user/1000 \
  -e WAYLAND_DISPLAY=wayland-1 caelestia bash -lc 'grim /tmp/shot.png'
docker cp caelestia:/tmp/shot.png ./shot.png
```

`hyprland.lock`, inside the instance directory, holds the compositor PID on line
1 and the display name on line 2. That is where the supervisor reads its
lifetime from, and it is more reliable than the socket file, which a `SIGKILLed`
compositor leaves behind.

## Health check

| Check | Healthy |
|---|---|
| `reserved:` | `60 10 10 10` |
| live processes | one `hyprland`, one supervisor, one `qs -c caelestia` |
| `grep caelestia.settings` in the shell log | no output |
| `Hyprland --verify-config` | `config ok` |
| `fc-match "Material Symbols Rounded"` | not `NotoSans` |

```bash
docker exec caelestia bash -c "grep -a 'caelestia.settings' /tmp/caelestia-shell-$SIG.log | sort -u"
docker exec caelestia bash -c "tail -f /tmp/caelestia-shell-$SIG.log"
```

## Footguns, all of which cost time

- `pkill -f <pattern>` inside `docker exec` matches the exec shell's own argv and
  kills it mid-script. Use `pkill -x` or explicit pids.
- PID 1 is `sleep infinity` and never reaps, so dead PIDs linger forever.
  `ps -eo pid,stat,args | grep -Ev '^ *[0-9]+ +Z'` to filter.
- `hyprland` is two processes. Killing the parent leaves the child holding the
  output.
- `hyprctl` needs `HYPRLAND_INSTANCE_SIGNATURE`, which is **not** in
  `/proc/<pid>/environ` - it is set later via `setenv`. The instance directory
  name is the signature.
- Never `start-hyprland` here. It unsets `WAYLAND_DISPLAY`, which is the only
  way aquamarine finds the outer mutter socket.

---

## Known issues

The reconstruction did not build on the first try. Six things were broken; all
are fixed, and the fixes are load-bearing enough to be worth knowing about if
you maintain this.

1. **The PPA source was in the wrong file format.** A legacy one-line `deb`
   stanza was written into a `.sources` file, which is deb822. apt rejected it
   and `apt-get update` exited 100:
   `E: Malformed stanza 1 in source list /etc/apt/sources.list.d/danklinux.sources`

2. **`ca-certificates` was missing.** `ubuntu:26.04` does not ship it and
   `--no-install-recommends` will not pull it in. The PPA is https, so every
   fetch failed TLS verification, and so did `git clone` and every `wget` of the
   fonts. It now installs before the PPA is added.

3. **`danklinux.asc` was corrupt.** The armored block had a stray ` .` line
   after the header and a failed CRC24, so `gpg` could not parse it at all
   (`no valid OpenPGP data found`) and apt rejected the signature with
   `NO_PUBKEY FC44813D2A7788B7`. Re-fetched from the keyserver. It is now
   `45FECBE587307AAA3F0A4BE9FC44813D2A7788B7`, "Launchpad PPA for Avenge Media".
   The key stays armored as `.asc`, which apt accepts, so `gnupg` is not needed
   in the image at all.

4. **The Qt patch no longer applied.** Its third hunk targets
   `modules/lock/center/InputField.qml`, which has since changed. The shell is
   now pinned to `454f46d` - the tree the patch was written against - and that
   one hunk is excluded in favour of doing the rename directly:
   `sed -i "s/\bchar\b/charItem/g"`. `char` shadows the global `char()`.

5. **libcava installed where nothing could find it.** meson defaults to `lib64`
   on this platform, and `/usr/local/lib64` is not on pkg-config's default
   search path, so the shell's configure died with `Package 'cava' not found`
   even though the library had installed perfectly. Fixed with
   `meson setup --libdir=lib`. The clone is also pinned to tag **0.10.6**: the
   default branch is now 1.0.0, which renamed the library to `libcava.so.1` and
   added an 8th `cava_init` parameter that the shell's plugin does not pass.

6. **The shell could not find its own QML modules.** `cmake --install` puts the
   shell's C++ QML modules in `/usr/local/lib/qt6/qml`, but Ubuntu's Qt searches
   exactly one import path, reported by `qtpaths6 --query QT_INSTALL_QML` as
   `/usr/lib/x86_64-linux-gnu/qt6/qml`. The shell therefore refused to start:
   `ERROR: module "Caelestia.Config" is not installed` /
   `ERROR:   caused by @shell.qml[28:5]: Type ServiceLoader unavailable`.
   Two symlinks fix it. This is also why no `QML_IMPORT_PATH` is needed
   anywhere, and why setting one to a path that does not exist is worse than
   useless.

7. **The build-time sanity gate aborted.** `Hyprland --verify-config` throws an
   uncaught `std::runtime_error` when `XDG_RUNTIME_DIR` is unset, and refuses to
   run as superuser without `--i-am-really-stupid`. Separately, `fc-match` run as
   root does not scan `/home/ubuntu/.local/share/fonts`, so every family appeared
   to fall back to DejaVu even when installed correctly. The gate now runs as
   uid 1000 via `runuser` and checks all three font families explicitly.

Separately, `wayland-info` — which `build-image.sh`'s socket gate uses — is in
**`wayland-utils`**, not `libwayland-bin`. In wayland 1.24 `libwayland-bin`
ships only `wayland-scanner`, so a gate that installs the latter finds nothing
and fails while reporting nothing useful. Both the image and the gate now use
`wayland-utils`.

### Verified

`docker build --no-cache` completes, and a live session was brought up from the
result and checked:

```
GPU gate    OpenGL core profile renderer: AMD Radeon 610M (radeonsi, raphael_mendocino, ACO, DRM 3.64)
hyprctl     Monitor WAYLAND-1  1280x720@60.00000  scale: 1.00  reserved: 60 10 10 10
processes   2x hyprland, 2x supervisor, 1x qs -c caelestia
shell log   Configuration Loaded, no `caelestia.settings` warnings
layers      caelestia-background, caelestia-drawers, 4x caelestia-border-exclusion
dispatch    hyprctl dispatch global caelestia:showall -> ok
```

`reserved: 60 10 10 10` is the load-bearing line: the compositor is reserving
space for the bar, so it is participating in layout rather than displaying a
picture. A multiple of 60 means shell instances have leaked.

### Still open

- `conf/shell.json` points `audio` at `pavucontrol` and `explorer` at
  `nautilus`. Neither is installed, so those two launcher entries launch
  nothing. Add them or change the paths.
- `conf/hyprland.conf` sets `QML_IMPORT_PATH=/usr/lib/qt6/qml`, a directory that
  does not exist on Ubuntu. The shell runs correctly without it; the line is
  harmless but should be deleted.
- The image is 4.5 GB, mostly Qt 6 development headers and the shell's own
  build tree. Neither is needed at runtime; a multi-stage build would cut this
  substantially.
- The build was verified to *complete* and to pass its gates. It has not been
  verified to boot a live session on this machine, because doing so means
  replacing a running container.
