# Nested Caelestia desktop: Hyprland + the Caelestia Quickshell, on ubuntu:26.04.
#
# Reconstructed from the verified contents of the working `caelestia` container
# (dpkg database, CMake caches, install prefixes, /var/log/apt/history.log).
# It reproduces that container's filesystem; it is NOT the artifact that was
# built interactively. That one is the committed image:
#
#     docker commit caelestia caelestia-full
#
# Each step below carries a comment explaining why it exists.
FROM ubuntu:26.04

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
RUN printf 'deb [signed-by=/usr/share/keyrings/danklinux.gpg] https://ppa.launchpadcontent.net/avengemedia/danklinux/ubuntu/ resolute main\n' \
      > /etc/apt/sources.list.d/danklinux.sources
COPY danklinux.asc /usr/share/keyrings/danklinux.asc
RUN gpg --dearmor < /usr/share/keyrings/danklinux.asc > /usr/share/keyrings/danklinux.gpg \
 && rm /usr/share/keyrings/danklinux.asc \
 && apt-get update -qq

# ---------------------------------------------------------------------------
# 2. Compositor, GPU stack, tools.
#
# --group-add is NOT used here: GIDs are passed at `docker run` time because
# `--group-add video` fails when the name is absent from the image's /etc/group
# (the host's render group is gid 990 and the image has no such entry).
# ---------------------------------------------------------------------------
RUN apt-get install -y -qq --no-install-recommends \
      hyprland hyprland-qtutils foot grim libwayland-bin \
      libgl1-mesa-dri libegl1 libgbm1 mesa-utils libseat1 libinput10 \
      libxkbcommon0 libxkbcommon-x11-0 libwayland-client0 libpixman-1-0 \
      locales adwaita-icon-theme hicolor-icon-theme fontconfig \
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
# 4. Build toolchain. Only the shell itself, m3shapes and libcava need this.
# ---------------------------------------------------------------------------
RUN apt-get install -y -qq --no-install-recommends \
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
RUN git clone --depth 1 https://github.com/LukashonakV/cava /tmp/libcava \
 && meson setup /tmp/libcava/build /tmp/libcava --buildtype=release -Ddefault_library=shared \
 && meson compile -C /tmp/libcava/build \
 && meson install -C /tmp/libcava/build \
 && ldconfig

# ---------------------------------------------------------------------------
# 7. The Caelestia shell.
#
# Full clone, not shallow: the build reads its version from `git describe`.
# The qt6.10-compat patch is mandatory on Ubuntu's Qt 6.10.2 - without it the
# shell fails to load with three separate errors. See decision D12.
# ---------------------------------------------------------------------------
RUN git clone https://github.com/caelestia-dots/shell.git /home/ubuntu/.config/quickshell/caelestia
COPY qt6.10-compat.patch /tmp/qt6.10-compat.patch
RUN cd /home/ubuntu/.config/quickshell/caelestia \
 && git apply /tmp/qt6.10-compat.patch \
 && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
 && cmake --build build \
 && cmake --install build

# ---------------------------------------------------------------------------
# 8. Fonts. Material Symbols Rounded is the one that matters: Caelestia draws
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
 && for f in "Material Symbols Rounded" "Rubik" "CaskaydiaCove NF"; do fc-match "$f"; done

COPY --chown=ubuntu:ubuntu conf/hyprland.conf                    /home/ubuntu/.config/hypr/hyprland.conf
COPY --chown=ubuntu:ubuntu conf/shell.json                       /home/ubuntu/.config/caelestia/shell.json
COPY --chown=ubuntu:ubuntu conf/qml_color.json                   /home/ubuntu/.config/quickshell/qml_color.json
COPY --chown=ubuntu:ubuntu conf/caelestia-shell-supervisor.sh    /home/ubuntu/bin/caelestia-shell-supervisor.sh
COPY --chown=ubuntu:ubuntu cleanup.sh                            /home/ubuntu/cleanup.sh
RUN chmod +x /home/ubuntu/bin/caelestia-shell-supervisor.sh /home/ubuntu/cleanup.sh \
 && mkdir -p /home/ubuntu/Pictures/Wallpapers

# Sanity gate: fail the build rather than discover this at runtime.
RUN Hyprland --verify-config 2>&1 | grep -q "config ok" \
 && fc-match "Material Symbols Rounded" | grep -qv NotoSans \
 && command -v qs && qs --version

CMD ["sleep", "infinity"]
