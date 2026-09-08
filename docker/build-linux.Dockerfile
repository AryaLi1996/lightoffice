# Reproducible build image for the LightOffice desktop editors (Linux).
#
# Why this exists
# ---------------
# The ONLYOFFICE desktop build pulls v8 with depot_tools from
# chromium.googlesource.com, and depot_tools bootstraps its CIPD client from
# chrome-infra-packages.appspot.com. Two problems follow from that:
#
#   1. depot_tools is normally cloned at HEAD. A revision that fetched v8 fine
#      on 2026-09-07 could not bootstrap its CIPD client on 2026-09-08, and
#      every build in between broke through no change of ours. An unpinned
#      HEAD dependency is a build that works until someone else's Tuesday.
#   2. Many networks — including sandboxed CI and corporate egress policies —
#      cannot reach either host at all, so the build cannot even start.
#
# This image solves both by cloning depot_tools ONCE, at image-build time,
# pinned to a known-good revision, and bootstrapping it there. Builds run from
# the image copy it in via LIGHTOFFICE_DEPOT_TOOLS_CACHE and never touch
# Google's infrastructure. Push the built image to a registry and the pin
# travels with it.
#
# Base is ubuntu:24.04 to match the ubuntu-latest runner the pipeline is
# verified on. On 24.04 v8's bundled libstdc++ is older than the host's and the
# link fails; scripts/build_desktop.sh applies upstream's fix_ubuntu24 remedy
# for that, so nothing extra is needed here.
#
# Build:
#   docker build -f docker/build-linux.Dockerfile -t lightoffice-build:24.04 .
#
# Use (from the repo root; the container does the whole pipeline):
#   docker run --rm -v "$PWD:/work" -w /work lightoffice-build:24.04 \
#     bash -c 'scripts/bootstrap.sh /tmp/src \
#           && LIGHTOFFICE_SRC=/tmp/src scripts/fetch_prebuilts.sh \
#           && scripts/apply_overlay.sh /tmp/src \
#           && scripts/apply_build_flags.sh /tmp/src \
#           && LIGHTOFFICE_SRC=/tmp/src scripts/build_desktop.sh \
#           && LIGHTOFFICE_SRC=/tmp/src scripts/package.sh --version 1.0.0'
#
# Expect a first build of roughly two hours, most of it v8's 2929 targets.

FROM ubuntu:24.04

# Keeps apt from stopping on tzdata's interactive prompt.
ENV DEBIAN_FRONTEND=noninteractive

# Two groups, deliberately: the first is what the desktop editors need to
# compile and package (kept in step with the same list in
# .github/workflows/release.yml), the second is what fetching and driving the
# build needs.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      build-essential cmake p7zip-full autoconf libtool \
      qtbase5-dev qtbase5-private-dev qttools5-dev libqt5svg5-dev \
      libgtk-3-dev libglu1-mesa-dev libx11-xcb-dev libxi-dev \
      libxrender-dev libxkbcommon-dev libxkbcommon-x11-dev \
      libnotify-dev libcups2-dev libdbus-1-dev libicu-dev \
      libasound2-dev libatspi2.0-dev dpkg-dev \
      git curl ca-certificates python3 python3-venv rsync file \
 && rm -rf /var/lib/apt/lists/*

# Anchored on evidence rather than a guessed SHA: the last depot_tools revision
# from before the day the v8 fetch was last known to work. Keep this in step
# with PIN_BEFORE in scripts/fetch_prebuilts.sh — the two are the same pin,
# and the image is only useful if it agrees with the fallback path.
ARG DEPOT_TOOLS_BEFORE=2026-09-07
ARG DEPOT_TOOLS_URL=https://chromium.googlesource.com/chromium/tools/depot_tools.git

ENV LIGHTOFFICE_DEPOT_TOOLS_CACHE=/opt/depot_tools-cache

# The pin and the bootstrap both happen here, while the network is available.
# ensure_bootstrap provisions depot_tools' own python3 and writes
# python3_bin_reldir.txt; without that file the build dies with
# "python3_bin_reldir.txt not found" the moment self-update is disabled, so
# fail the image build rather than ship a cache that cannot be used offline.
RUN git clone --quiet "$DEPOT_TOOLS_URL" "$LIGHTOFFICE_DEPOT_TOOLS_CACHE" \
 && pin="$(git -C "$LIGHTOFFICE_DEPOT_TOOLS_CACHE" rev-list -1 --before="$DEPOT_TOOLS_BEFORE" HEAD)" \
 && test -n "$pin" \
 && git -C "$LIGHTOFFICE_DEPOT_TOOLS_CACHE" checkout --quiet --detach "$pin" \
 && echo "depot_tools pinned to $pin" \
 && ( cd "$LIGHTOFFICE_DEPOT_TOOLS_CACHE" && DEPOT_TOOLS_UPDATE=0 ./ensure_bootstrap ) \
 && test -f "$LIGHTOFFICE_DEPOT_TOOLS_CACHE/python3_bin_reldir.txt" \
 && echo "depot_tools bootstrapped: $(cat "$LIGHTOFFICE_DEPOT_TOOLS_CACHE/python3_bin_reldir.txt")"

# Record what got baked in, so an image in a registry can be identified without
# running it: docker run --rm IMAGE cat /etc/lightoffice-build-image
RUN { echo "base=ubuntu:24.04"; \
      echo "depot_tools_pin=$(git -C "$LIGHTOFFICE_DEPOT_TOOLS_CACHE" rev-parse HEAD)"; \
      echo "depot_tools_before=$DEPOT_TOOLS_BEFORE"; \
    } > /etc/lightoffice-build-image

# Self-update is off for every build from this image: it is precisely the drift
# this image exists to eliminate.
ENV DEPOT_TOOLS_UPDATE=0

WORKDIR /work
CMD ["/bin/bash"]
