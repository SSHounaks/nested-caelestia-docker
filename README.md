# nested-caelestia-docker

Runs the [Caelestia](https://github.com/caelestia-dots) desktop shell inside a
Docker container, on a nested Hyprland compositor, on top of an untouched
GNOME/Wayland session.

Everything needed to build and run it, and nothing that touches the host.

> **Status: the container works, this `Dockerfile` has not been run end to end.**
> It was reconstructed from the verified contents of a working container (dpkg
> database, CMake caches, install prefixes, apt history) rather than being the
> artifact that was built interactively. Expect to fix it on a first run; see
> [Known issues](#known-issues).

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

Verified against a clean `ubuntu:26.04`, not guessed:

1. **Step 1 fails: the PPA source is in the wrong format.** The `Dockerfile`
   writes a legacy one-line `deb` stanza into a file named `.sources`, but
   `.sources` is deb822. apt rejects it and `apt-get update` exits 100:
   ```
   E: Malformed stanza 1 in source list /etc/apt/sources.list.d/danklinux.sources (type)
   ```
   It needs `Types: / URIs: / Suites: resolute / Components: main / Signed-By:`.

2. **Step 8 fails: no `ca-certificates`.** `ubuntu:26.04` does not ship it and
   `--no-install-recommends` will not pull it in, so every `wget` of the fonts
   dies with `rc=5` (SSL verification). Adding `ca-certificates` to the package
   list is the entire fix.

3. `conf/shell.json` points `audio` at `pavucontrol` and `explorer` at
   `nautilus`. Neither is installed by the `Dockerfile`, so those two launcher
   entries launch nothing.

4. Nothing is version-pinned. Three `git clone`s, two of them `--depth 1`. The
   `qt6.10-compat.patch` `git apply` and the `cava_init` signature match will
   both break the moment upstream moves. Pin the commits if you care about
   reproducibility.

5. No `--init` on the container you already have running. PID 1 is
   `sleep infinity` and never reaps, so every finished `docker exec` leaves a
   permanent zombie and `pgrep` looks broken. `build-image.sh` already passes
   `--init`; the fix only applies to containers created before that.
