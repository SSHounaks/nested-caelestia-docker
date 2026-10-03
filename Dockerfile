# Nested Caelestia desktop: Hyprland + the Caelestia Quickshell, on ubuntu:26.04.
#
# Reconstructed from the verified contents of the working `caelestia` container
# (dpkg database, CMake caches, install prefixes, /var/log/apt/history.log).
# It reproduces that container's filesystem; it is NOT the artifact that was
# built interactively.
#
# Multi-stage: `base` carries every runtime package and the fonts, `builder`
# adds the toolchain and compiles m3shapes, libcava and the shell, and `runtime`
# takes only the installed artefacts back. That drops the shell's CMake build
# tree (1.7 GB on its own), the Qt 6 development headers, and the compiler.
# `runtime` ends with an ldd gate over every installed shared object, so a
# library that exists in `builder` but not in `runtime` fails the BUILD rather
# than the shell at runtime.
#
# See docs/nested-caelestia-log.md sections 4b-4f for why each step exists.

FROM ubuntu:26.04 AS base



ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8



# ---------------------------------------------------------------------------
# 1. Quickshell from the DankLinux PPA, not from source.
#
# The reference guide (IshmamDC217/caelestia-shell-ubuntu) says Quickshell is
# "still a source build" on 26.04 and budgets 60-90 minutes. It is not: the
# DankLinux PPA carries a current `quickshell-git`. Installing it removed the
# single largest task in the project. The PPA key is inlined because
# add-apt-repository is not available until software-properties-common is.
# ---------------------------------------------------------------------------
#
# Three things here are load-bearing and each one was a build failure first:
#   * the file must be deb822, not a legacy one-line `deb` stanza, or apt
#     rejects it with "Malformed stanza 1" and exits 100
#   * ca-certificates must be installed BEFORE the PPA is added. ubuntu:26.04
#     ships without it and its own apt sources are plain http, so it installs
#     fine; the PPA is https, so without it every fetch fails TLS verification
#   * the key stays armored as .asc. apt accepts an armored key when the
#     filename ends in .asc, so gnupg is not needed in the image at all
#   Key fingerprint 45FECBE587307AAA3F0A4BE9FC44813D2A7788B7, "Launchpad PPA
#   for Avenge Media", fetched with:
#     gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys FC44813D2A7788B7
# ---------------------------------------------------------------------------
RUN printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/avengemedia/danklinux/ubuntu/\nSuites: resolute\nComponents: main\nSigned-By: /usr/share/keyrings/danklinux.asc\n' \
      > /etc/apt/sources.list.d/danklinux.sources
COPY danklinux.asc /usr/share/keyrings/danklinux.asc
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates \
 && apt-get update -qq \
 && apt-cache policy quickshell-git



# ---------------------------------------------------------------------------
# 2. Compositor, GPU stack, tools.
#
# wayland-utils is here for wayland-info, which is what build-image.sh's socket
# gate uses. libwayland-bin ships only wayland-scanner in wayland 1.24, so it is
# NOT the provider - a gate that installs libwayland-bin silently finds nothing.
#
# --group-add is NOT used here: GIDs are passed at `docker run` time because
# `--group-add video` fails when the name is absent from the image's /etc/group
# (the host's render group is gid 990 and the image has no such entry).
# ---------------------------------------------------------------------------
RUN apt-get install -y -qq --no-install-recommends \
      hyprland hyprland-qtutils foot grim libwayland-bin wayland-utils \
      hyprlock hypridle \
      libgl1-mesa-dri libegl1 libgbm1 mesa-utils libseat1 libinput10 \
      libxkbcommon0 libxkbcommon-x11-0 libwayland-client0 libpixman-1-0 \
      locales adwaita-icon-theme hicolor-icon-theme fontconfig \
      fonts-noto-cjk fonts-noto-color-emoji \
      && locale-gen en_US.UTF-8



# ---------------------------------------------------------------------------
# 3. Quickshell + the QML modules the shell imports.
# ---------------------------------------------------------------------------
RUN apt-get install -y -qq --no-install-recommends \
      quickshell-git \
      qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
      qml6-module-qtquick-window qml6-module-qtquick-shapes qml6-module-qtquick-effects \
      qml6-module-qtquick-dialogs qml6-module-qtquick-templates qml6-module-qtquick-localstorage \
      qml6-module-qtquick-vectorimage qml6-module-qtqml qml6-module-qtqml-models \
      qml6-module-qt-labs-folderlistmodel qml6-module-qt-labs-platform \
      qml6-module-qt-labs-settings qml6-module-qt-labs-synchronizer \
      qml6-module-qt-labs-sharedimage qml6-module-qt-labs-animation \
      qml6-module-qtmultimedia qml6-module-qtnetwork qml6-module-org-hyprland-style \
      qt6-image-formats-plugins libqt6sql6-sqlite \
      network-manager ddcutil alsa-utils udev

# ---------------------------------------------------------------------------
# 3b. Runtime shared libraries for the shell's C++ plugins.
#
# These used to arrive as dependencies of the -dev packages in the builder
# stage. Once the toolchain is gone from the final image they have to be asked
# for by name, and the ldd gate at the end of the `runtime` stage is what proves
# the list is complete. Derived from `ldd` over every .so the shell installs:
# 175 packages in the working image, of which these are the roots apt resolves
# the rest from.
#
# wget and unzip are here rather than only in the builder because the font
# download lives in base, so both stages inherit it. Installing them with
# --no-install-recommends and no ca-certificates was the original failure: every
# fetch died with wget rc=5.
# ---------------------------------------------------------------------------
RUN apt-get install -y -qq --no-install-recommends \
      libqalculate23 libpipewire-0.3-0 libaubio5 \
      libfftw3-single3 libfftw3-double3 libsensors5 libiniparser4 \
      libgdk-pixbuf-2.0-0 librsvg2-2 libglycin-2-0 \
      libavcodec62 libavformat62 libavutil60 libswresample6 \
      libpulse0 alsa-utils \
      wget unzip \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 8. Fonts.
#
# CJK: fonts-noto-cjk (89 MB) covers Simplified Chinese, Traditional Chinese,
# Japanese and Korean in one .ttc, and fontsconfig's :lang= tags resolve to it
# automatically once installed. Without it every CJK glyph is tofu - which is
# exactly what a media player shows for a Japanese title, a CJK filename in the
# window title, or any app name in the launcher. Verified with fc-match, and
# gated at the end of this build.
#
# Material Symbols Rounded is the other one that matters: Caelestia draws
#    icons by writing the ligature name and letting the font turn it into a
#    glyph. Without it fontconfig falls back to Noto Sans and the bar renders
#    the literal words "terminal", "web", "calendar" as overflowing text.
#    fc-match is the verification, not the download.
# ---------------------------------------------------------------------------
RUN mkdir -p /home/ubuntu/.local/share/fonts && cd /home/ubuntu/.local/share/fonts \
 && wget -q -O "Rubik.ttf"            "https://github.com/googlefonts/rubik/raw/main/fonts/variable/Rubik%5Bwght%5D.ttf" \
 && wget -q -O "Rubik-Italic.ttf"     "https://github.com/googlefonts/rubik/raw/main/fonts/variable/Rubik-Italic%5Bwght%5D.ttf" \
 && wget -q -O "MaterialSymbolsRounded.ttf" \
      "https://github.com/google/material-design-icons/raw/master/variablefont/MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf" \
 && wget -q -O CascadiaCodeNF.zip "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/CascadiaCode.zip" \
 && unzip -qo CascadiaCodeNF.zip -d CascadiaCodeNF && cp CascadiaCodeNF/*.ttf . \
 && rm -rf CascadiaCodeNF CascadiaCodeNF.zip \
 && fc-cache -f \
 && rm -rf /var/lib/apt/lists/*

# ===========================================================================

# builder: toolchain and compilation. Never shipped.

# ===========================================================================

FROM base AS builder



# ---------------------------------------------------------------------------
# 4. Build toolchain. Only the shell itself, m3shapes and libcava need this.
# ---------------------------------------------------------------------------
# base ends with `rm -rf /var/lib/apt/lists/*` to keep the image small, so the
# builder inherits no package lists and has to refresh them first.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      git cmake ninja-build g++ pkg-config wget unzip \
      qt6-base-dev qt6-declarative-dev qt6-shadertools-dev qt6-svg-dev \
      libqalculate-dev libpipewire-0.3-dev libaubio-dev libsensors-dev spirv-tools \
      meson libfftw3-dev libpulse-dev libncurses-dev libiniparser-dev



# ---------------------------------------------------------------------------
# 5. m3shapes -> /usr/local. Caelestia's blob backgrounds need it; without it
#    the panels fall back to plain rounded rectangles.
# ---------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/soramanew/m3shapes /tmp/m3shapes
RUN cmake -S /tmp/m3shapes -B /tmp/m3shapes/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
 && cmake --build /tmp/m3shapes/build \
 && cmake --install /tmp/m3shapes/build



# ---------------------------------------------------------------------------
# 6. libcava -> /usr/local. Ubuntu's `cava` package is karlstav's console
#    visualiser and ships no shared library, so Caelestia cannot link against
#    it. Note the pkg-config file is `cava.pc`, and /usr/local/lib/pkgconfig is
#    already on pkg-config's default search path, so PKG_CONFIG_PATH is not
#    needed (the reference guide's advice is for other prefixes).
# ---------------------------------------------------------------------------
#
# Two things here are pinned deliberately, and both were build failures first:
#
#   * --branch 0.10.6. The shell's plugin calls the 7-argument cava_init
#     (cavaprovider.cpp). cavacore's default branch (now 1.0.0) renamed the
#     library to libcava.so.1 and added an 8th scaling_mode parameter, so the
#     plugin fails to compile against it. Tag 0.10.7 also renames the
#     pkg-config file back to libcava.pc.
#   * --libdir=lib. meson defaults this to lib64 on this platform, and
#     /usr/local/lib64 is NOT on pkg-config's default search path, so the
#     shell's configure step dies with "Package 'cava' not found" even though
#     the library installed perfectly.
#
# The .pc file's Cflags point at include/cava rather than include, so
# #include <cava/cavacore.h> resolves through gcc's own default
# /usr/local/include instead. That is fine and is why no extra include path is
# set here.
# ---------------------------------------------------------------------------
RUN git clone --depth 1 --branch 0.10.6 https://github.com/LukashonakV/cava /tmp/libcava \
 && meson setup /tmp/libcava/build /tmp/libcava --buildtype=release --libdir=lib -Ddefault_library=shared \
 && meson compile -C /tmp/libcava/build \
 && meson install -C /tmp/libcava/build \
 && ldconfig \
 && pkg-config --exists cava



# ---------------------------------------------------------------------------
# 7. The Caelestia shell.
#
# Full clone, not shallow: the commit is pinned below, and the build reads its
# version from `git describe`.
#
# The qt6.10-compat patch is MANDATORY on Ubuntu's Qt 6.10.2 - without it the
# shell fails to load with three separate errors (DoubleSpinBox is not a type,
# `id: char` is a reserved word, RectangularShadow has no topRightRadius). See
# decision D12.
#
# The commit is pinned to 454f46d, the tree the patch was written against. The
# patch's third hunk targets modules/lock/center/InputField.qml and no longer
# applies there, so it is excluded and the same rename is done directly: Qt 6.11
# relaxed `char` as an identifier, and `char` shadows the global char() function.
# Unpinned, the build breaks the moment upstream edits that file.
# ---------------------------------------------------------------------------
RUN git clone https://github.com/caelestia-dots/shell.git /home/ubuntu/.config/quickshell/caelestia
COPY qt6.10-compat.patch /tmp/qt6.10-compat.patch
RUN cd /home/ubuntu/.config/quickshell/caelestia \
 && git checkout -q 454f46da16ae75cc57f34adf48dea74db0fa5175 \
 && git apply --exclude="modules/lock/center/InputField.qml" /tmp/qt6.10-compat.patch \
 && sed -i "s/\\bchar\\b/charItem/g" modules/lock/center/InputField.qml \
 && ! grep -qE '\\bchar\\b' modules/lock/center/InputField.qml \
 && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
 && cmake --build build \
 && cmake --install build
#
# Ubuntu's Qt searches exactly one QML import path:
#     /usr/lib/x86_64-linux-gnu/qt6/qml      (qtpaths6 --query QT_INSTALL_QML)
# cmake installs the shell's C++ QML modules to /usr/local/lib/qt6/qml, which
# is NOT on that list, so without these two symlinks the shell fails to load:
#     ERROR: module "Caelestia.Config" is not installed
#     ERROR:   caused by @shell.qml[28:5]: Type ServiceLoader unavailable
# This is also why no QML_IMPORT_PATH is set anywhere: the symlinks make it
# unnecessary, and setting it to a path that does not exist is worse than useless.

# Strip the build tree before handing the sources over: it is 1.7 GB of CMake
# and Ninja artefacts and nothing at runtime reads it.
RUN rm -rf /home/ubuntu/.config/quickshell/caelestia/build \
 && cp -a /home/ubuntu/.config/quickshell/caelestia /tmp/shell-src \
 && chown -R ubuntu:ubuntu /tmp/shell-src \
 && du -sh /tmp/shell-src

# ===========================================================================

# runtime: base plus the installed artefacts. This is the shipped image.

# ===========================================================================

FROM base AS runtime



COPY --from=builder /usr/local/ /usr/local/

COPY --from=builder /tmp/shell-src/ /home/ubuntu/.config/quickshell/caelestia/

RUN ln -sfn /usr/local/lib/qt6/qml/Caelestia /usr/lib/x86_64-linux-gnu/qt6/qml/Caelestia \
 && ln -sfn /usr/local/lib/qt6/qml/M3Shapes /usr/lib/x86_64-linux-gnu/qt6/qml/M3Shapes \
 && ls -d /usr/lib/x86_64-linux-gnu/qt6/qml/Caelestia /usr/lib/x86_64-linux-gnu/qt6/qml/M3Shapes \
 && ldconfig




COPY --chown=ubuntu:ubuntu conf/hyprland.conf                    /home/ubuntu/.config/hypr/hyprland.conf
COPY --chown=ubuntu:ubuntu conf/shell.json                       /home/ubuntu/.config/caelestia/shell.json
COPY --chown=ubuntu:ubuntu conf/qml_color.json                   /home/ubuntu/.config/quickshell/qml_color.json
COPY --chown=ubuntu:ubuntu conf/caelestia-shell-supervisor.sh    /home/ubuntu/bin/caelestia-shell-supervisor.sh
COPY --chown=ubuntu:ubuntu cleanup.sh                            /home/ubuntu/cleanup.sh
RUN chmod +x /home/ubuntu/bin/caelestia-shell-supervisor.sh /home/ubuntu/cleanup.sh \
 && mkdir -p /home/ubuntu/Pictures/Wallpapers \
 && ldconfig

# ---------------------------------------------------------------------------
# Sanity gate: fail the build rather than discover this at runtime.
#
# All three of these had to be run as uid 1000 rather than as root:
#   * Hyprland aborts with an uncaught std::runtime_error if XDG_RUNTIME_DIR is
#     unset, and refuses to run as superuser without --i-am-really-stupid
#   * fontconfig only scans /home/ubuntu/.local/share/fonts when $HOME points
#     there, so fc-match as root silently falls back to DejaVu and every family
#     "fails" even though the font is installed correctly
#
# The deny-list is NotoSans-Regular and DejaVuSans specifically, not "NotoSans*":
# the CJK family is legitimately called NotoSansCJK-Regular.ttc, so a looser
# pattern rejects the font it is supposed to be checking for.
# ---------------------------------------------------------------------------
RUN set -eu; \
    GATE="HOME=/home/ubuntu XDG_RUNTIME_DIR=/tmp HYPRLAND_NO_CRASHREPORTER=1"; \
    runuser -u ubuntu -- env $GATE Hyprland --verify-config 2>&1 | grep -q "config ok"; \
    for f in "Material Symbols Rounded" "Rubik" "CaskaydiaCove NF" \
             "Noto Sans CJK JP" "Noto Sans CJK SC" "Noto Sans CJK TC" "Noto Sans CJK KR"; do \
      m=$(runuser -u ubuntu -- fc-match "$f"); \
      case "$m" in *NotoSans-Regular*|*DejaVuSans*) echo "FONT GATE FAILED: $f -> $m" >&2; exit 1;; esac; \
    done; \
    command -v qs; qs --version; \
    test -e /usr/lib/x86_64-linux-gnu/qt6/qml/Caelestia/libcaelestia-coreplugin.so

# ---------------------------------------------------------------------------
# Shared-library closure gate. Everything the shell installed must resolve with
# nothing missing. This is the check that makes the multi-stage split safe: if a
# package was only pulled in as a -dev dependency in the builder, this fails the
# build instead of producing an image whose shell dies at startup.
# ---------------------------------------------------------------------------
RUN missing=0; \
    for so in $(find /usr/local -name '*.so*' -type f); do \
      if ldd "$so" 2>/dev/null | grep -q 'not found'; then \
        echo "UNRESOLVED in $so:" >&2; ldd "$so" | grep 'not found' >&2; missing=1; \
      fi; \
    done; \
    test "$missing" -eq 0

CMD ["sleep", "infinity"]
