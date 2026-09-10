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
  qtmultimedia5-dev libqt5x11extras5-dev \
  libgtk-3-dev libglu1-mesa-dev libx11-xcb-dev libxi-dev \
  libxrender-dev libxkbcommon-dev libxkbcommon-x11-dev \
  libnotify-dev libcups2-dev libdbus-1-dev libicu-dev \
  libasound2-dev libatspi2.0-dev dpkg-dev \
  git curl ca-certificates python3 python3-venv rsync file \
  nodejs npm openjdk-11-jdk-headless mold \
  && npm install -g grunt-cli \
  && rm -rf /var/lib/apt/lists/*

# Why node, npm, grunt-cli and a JDK are here explicitly
# ------------------------------------------------------
# Upstream installs these itself, in build_tools/tools/linux/deps.py: nodejs
# (>= 16, else it adds the nodesource repo), npm, grunt-cli, and openjdk-11 for
# the closure compiler. But fetch_prebuilts.sh touches `packages_complete` to
# skip deps.py's ~40-package apt run, which skips those too.
#
# On a GitHub runner that goes unnoticed because node is preinstalled there. In
# THIS image nothing provides it, so the JS stage (sdkjs and web-apps, both
# driven by grunt) could never run: the image reported "build_desktop: FAILED"
# and banked no JS output at all, which is why every release run rebuilt
# web-apps from scratch no matter what the mtimes said.
# Presence, not version output: `grunt --version` exits non-zero without a local
# Gruntfile, which would fail the image build for no reason. Node's major version
# IS asserted, because deps.py requires >= 16 and silently reinstalls otherwise.
RUN set -eux; \
  node --version; npm --version; java -version; \
  command -v grunt >/dev/null; \
  major="$(node --version | sed 's/^v\([0-9]*\).*/\1/')"; \
  [ "$major" -ge 16 ] || { echo "node $major is below the 16 upstream requires" >&2; exit 1; }

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

# ---------------------------------------------------------------------------
# Prebuilt dependencies
# ---------------------------------------------------------------------------
# About 55 of the desktop build's 61 minutes rebuild pinned dependencies that
# never change between runs: boost, cef, icu, openssl, then v8's 2929 targets,
# then core/. Only the last few minutes compile the code we iterate on. Doing
# that work once, here, is the whole point of this stage.
#
# THE PATH MATTERS. ninja records absolute paths in build.ninja and .ninja_deps,
# so a tree built at one path and used at another is rebuilt from scratch and
# this stage buys nothing. LIGHTOFFICE_PREBUILT_SRC is therefore a fixed
# absolute path, and the release workflow extracts the tree back to the SAME
# path rather than to $RUNNER_TEMP. Change it in one place only.
ENV LIGHTOFFICE_PREBUILT_SRC=/opt/lightoffice/src

# ---------------------------------------------------------------------------
# Layered on purpose
# ---------------------------------------------------------------------------
# This used to be ONE RUN doing everything, which meant nothing cached: a
# one-line change to the branding overlay rebuilt v8 from scratch, 88 minutes
# of it. The stages below are ordered cheapest-and-most-stable first, and each
# COPYs only the files it actually needs, so BuildKit can reuse everything
# above the thing that changed. With --cache-from/--cache-to against GHCR (see
# build-image.yml) a rebuild that does not touch v8's inputs skips it entirely.
#
# The ordering that matters most: the CONTENT overlay (branding, theme,
# dictionaries) runs AFTER the expensive build, because it does not affect v8
# or core/ at all — only the JS and resource layers. Build-affecting patches
# (compile flags, Qt compatibility) must stay BEFORE it, or every object would
# be rebuilt.

# --- stage 1: bootstrap the pinned upstream tree (slow, changes rarely) -----
COPY scripts/bootstrap.sh /opt/lightoffice/repo/scripts/
COPY VERSION_LOCK /opt/lightoffice/repo/
RUN set -eux; cd /opt/lightoffice/repo; \
  scripts/bootstrap.sh "$LIGHTOFFICE_PREBUILT_SRC"

# --- stage 2: stage the prebuilts and the pinned depot_tools ----------------
COPY scripts/fetch_prebuilts.sh /opt/lightoffice/repo/scripts/
RUN set -eux; cd /opt/lightoffice/repo; \
  LIGHTOFFICE_SRC="$LIGHTOFFICE_PREBUILT_SRC" scripts/fetch_prebuilts.sh

# --- stage 3: patches that change how things COMPILE -----------------------
# These must precede the build: apply_build_flags.sh alters compile flags, and
# patch_qt_compat.sh fixes sources that will not compile against system Qt.
COPY scripts/apply_build_flags.sh scripts/patch_qt_compat.sh scripts/patch_v8_incremental.sh /opt/lightoffice/repo/scripts/
COPY overlay/build/ /opt/lightoffice/repo/overlay/build/
RUN set -eux; cd /opt/lightoffice/repo; \
  scripts/apply_build_flags.sh "$LIGHTOFFICE_PREBUILT_SRC"; \
  scripts/patch_qt_compat.sh "$LIGHTOFFICE_PREBUILT_SRC"; \
  scripts/patch_v8_incremental.sh "$LIGHTOFFICE_PREBUILT_SRC"

# --- stage 4: THE EXPENSIVE ONE (v8, core/, sdkjs, web-apps, desktop) ------
# `|| true` because the build is expected to get as far as desktop-apps; what
# we are banking is everything before it, and the release workflow rebuilds and
# reports that part properly. The log is kept IN the image: GitHub truncates
# BuildKit output for a layer this long, so printing the tail here never
# reaches the run log. build-image.yml reads the file out of the image instead.
COPY scripts/build_desktop.sh /opt/lightoffice/repo/scripts/
RUN set -eux; cd /opt/lightoffice/repo; \
  LIGHTOFFICE_SRC="$LIGHTOFFICE_PREBUILT_SRC" scripts/build_desktop.sh > /tmp/build.log 2>&1 \
  && echo "build_desktop: completed" > /tmp/build.status \
  || { echo "build_desktop: FAILED (expected at desktop-apps)" > /tmp/build.status; \
  tail -40 /tmp/build.log; }; \
  cat /tmp/build.status; \
  mkdir -p /var/log/lightoffice; \
  tail -200 /tmp/build.log > /var/log/lightoffice/build.tail.log; \
  rm -rf "$LIGHTOFFICE_PREBUILT_SRC"/core/Common/3dParty/openssl/build/*/share/doc || true

# --- stage 5: content overlay, then an INCREMENTAL rebuild -----------------
# Branding, theme and dictionary trimming touch no C++ at all, so putting them
# after stage 4 means changing a logo re-runs only this layer instead of v8.
# The rebuild is incremental: make and ninja find everything above unchanged.
COPY scripts/apply_overlay.sh scripts/trim_dictionaries.sh /opt/lightoffice/repo/scripts/
# trim_dictionaries.sh sources scripts/lib/portable.sh, so the directory has
# to keep its name — a bare `scripts/lib/` source would copy its CONTENTS.
COPY scripts/lib/ /opt/lightoffice/repo/scripts/lib/
COPY overlay/ /opt/lightoffice/repo/overlay/
COPY baseline/ /opt/lightoffice/repo/baseline/
RUN set -eux; cd /opt/lightoffice/repo; \
  scripts/apply_overlay.sh "$LIGHTOFFICE_PREBUILT_SRC"; \
  scripts/trim_dictionaries.sh "$LIGHTOFFICE_PREBUILT_SRC"; \
  LIGHTOFFICE_SRC="$LIGHTOFFICE_PREBUILT_SRC" scripts/build_desktop.sh >> /tmp/build.log 2>&1 \
  && echo "build_desktop: completed" > /tmp/build.status \
  || echo "build_desktop: FAILED (expected at desktop-apps)" > /tmp/build.status; \
  cat /tmp/build.status; \
  tail -200 /tmp/build.log > /var/log/lightoffice/build.tail.log; \
  # Drop v8's intermediates. Safe ONLY because patch_v8_incremental.sh added
  # the guard upstream already uses on Windows: without it ninja would find
  # the objects gone and rebuild all 2929 targets. libv8_monolith.a and the
  # generated headers under out.gn/*/gen stay — those are what doctrenderer
  # links and includes. Everything else in out.gn is intermediate.
  v8out="$LIGHTOFFICE_PREBUILT_SRC/core/Common/3dParty/v8_89/v8/out.gn/linux_64"; \
  if [ -f "$v8out/obj/libv8_monolith.a" ]; then \
  before=$(du -sm "$v8out" | cut -f1); \
  find "$v8out/obj" -name '*.o' -delete; \
  find "$v8out" -maxdepth 1 -name '.ninja_deps' -o -maxdepth 1 -name '.ninja_log' | xargs -r rm -f; \
  after=$(du -sm "$v8out" | cut -f1); \
  echo "v8 out.gn pruned: ${before} MiB -> ${after} MiB"; \
  else \
  echo "v8 out.gn NOT pruned: libv8_monolith.a absent"; \
  fi

# Record what got baked, so an image in a registry can be identified without
# running it: docker run --rm IMAGE cat /etc/lightoffice-build-image
# The manifest records every path a consuming build needs, not just the ones
# built earliest. The first version of this checked only libv8_monolith.a and
# core/'s libraries — both produced BEFORE sdkjs — so when the image was
# missing sdkjs/build/build.py the build_desktop failure above was swallowed,
# verification passed, the image published, and a release run spent 23 minutes
# restoring it before dying on the missing file. A check that cannot fail for
# the thing that breaks is not a check.
RUN { \
  printf 'prebuilt_src=%s\n' "$LIGHTOFFICE_PREBUILT_SRC"; \
  cat /tmp/build.status 2>/dev/null || echo "build_desktop: status unknown"; \
  printf 'v8_monolith=%s\n' "$(find "$LIGHTOFFICE_PREBUILT_SRC" -name 'libv8_monolith.a' -printf '%p (%s bytes)' 2>/dev/null | head -1)"; \
  printf 'core_libs=%s\n' "$(ls "$LIGHTOFFICE_PREBUILT_SRC/core/build/lib/linux_64" 2>/dev/null | tr '\n' ' ')"; \
  # sdkjs/build/build.py, deliberately: it is the file build_tools actually
  # runs (scripts/build_js.py _run_build_py), and it exists only AFTER the
  # sdkjs override in bootstrap.sh advances sdkjs to d8e4124. The tag's
  # sdkjs (b2f0aa1) ships Gruntfile.js + package.json and no build.py; the
  # override's commit ships build.py and neither of the others. PR #18
  # changed the commit AND switched this check to package.json in one go,
  # so the two halves contradicted and the gate blocked a CORRECT image.
  # Check what the build needs, not what happens to be lying around.
  for p in sdkjs/build/build.py web-apps/build/Gruntfile.js core/Common desktop-sdk desktop-apps/win-linux core-fonts/ASC.ttf document-templates/new; do \
  if [ -e "$LIGHTOFFICE_PREBUILT_SRC/$p" ]; then printf 'have %s\n' "$p"; \
  else printf 'MISSING %s\n' "$p"; fi; \
  done; \
  printf 'sdkjs_head=%s\n' "$(git -C "$LIGHTOFFICE_PREBUILT_SRC/sdkjs" rev-parse HEAD 2>/dev/null || echo unknown)"; \
  printf 'sdkjs_build_dir=%s\n' "$(ls "$LIGHTOFFICE_PREBUILT_SRC/sdkjs/build" 2>/dev/null | tr '\n' ' ')"; \
  printf 'prebuilt_size=%s\n' "$(du -sh "$LIGHTOFFICE_PREBUILT_SRC" 2>/dev/null | cut -f1)"; \
  # The question the manifest could not answer: is this image PACKAGEABLE?
  # "build_desktop: completed" means make.py returned 0, and deploy is its last
  # stage -- but nothing recorded whether deploy actually produced the tree
  # package.sh needs. Upstream deploys to build_tools/out (build_tools/scripts
  # resolves its output as scripts/../out), which is where package.sh and
  # verify_ac.sh look since 57b3204. Recording it here means a consuming build
  # knows before it starts whether it has to finish the build or can go straight
  # to packaging.
  printf 'deployed_binary=%s\n' "$(find "$LIGHTOFFICE_PREBUILT_SRC/build_tools/out" -type f -name DesktopEditors -printf '%p (%s bytes)' 2>/dev/null | head -1)"; \
  printf 'deployed_tree=%s\n' "$(du -sh "$LIGHTOFFICE_PREBUILT_SRC/build_tools/out" 2>/dev/null | cut -f1)"; \
  } >> /etc/lightoffice-build-image; cat /etc/lightoffice-build-image

# Two things the image never kept, both of which cost a 90-minute cycle to ask
# for again.
#
# The phase timings: this layer is the whole ONLYOFFICE build -- v8's 2929
# targets, boost, cef, icu, openssl, core/, sdkjs, web-apps, desktop-sdk,
# desktop-apps -- and it took ~88 minutes without ever saying which part. The
# markers scripts/build_desktop.sh now prints go into the manifest, so
# `docker run --rm IMAGE cat /etc/lightoffice-build-image` answers "where did
# the time go" with no log download and no rebuild. That is the measurement any
# argument about mold, ccache or -j has to start from.
#
# The full log: only a 200-line tail was retained, which is nothing for a build
# this long and routinely cuts off above the actual error. BuildKit truncates
# the layer's own output too, so the tail was all there was. Keeping the whole
# thing gzipped costs a few MB against a 24 GB image.
#
# Both run here rather than in the build layer above on purpose: this layer is
# seconds long, so changing it re-runs nothing expensive.
RUN set -eu; \
    mkdir -p /var/log/lightoffice; \
    if [ -f /tmp/build.log ]; then \
      gzip -c /tmp/build.log > /var/log/lightoffice/build.full.log.gz; \
      tail -400 /tmp/build.log > /var/log/lightoffice/build.tail.log; \
      { echo "build_log_bytes=$(wc -c < /tmp/build.log)"; \
        echo "build_phases:"; \
        grep '^=== phase' /tmp/build.log | sed 's/^/  /' || echo "  (none recorded)"; \
      } >> /etc/lightoffice-build-image; \
    else \
      echo "build_log=absent" >> /etc/lightoffice-build-image; \
    fi; \
    cat /etc/lightoffice-build-image

# --- the gate, INSIDE the image ---------------------------------------------
# This check used to live in build-image.yml, which had to `docker buildx build
# --load` so it could `docker run` the image to read the manifest. --load exports
# the whole ~24 GB image to a tarball and imports it into the daemon, so the
# runner held it three times over -- BuildKit cache, tar, daemon. Run
# 34363351869 spent 2h05m building and then died with "no space left on device"
# at "Free space left: 1 MB", 13.6 GB into a 14.43 GB layer.
#
# Running the same assertions here removes the reason to materialise the image
# locally at all: build-image.yml can push straight to the registry, and an image
# that fails this never gets pushed because the build itself fails. The layer is
# a few lines of output, so BuildKit does not truncate it the way it truncates
# the build layer.
RUN set -eu; \
    manifest="$(cat /etc/lightoffice-build-image)"; \
    fail=0; \
    case "$manifest" in \
      *libv8_monolith.a*) echo "gate: v8 present" ;; \
      *) echo "gate: ERROR image has no libv8_monolith.a -- the v8 build did not complete" >&2; fail=1 ;; \
    esac; \
    case "$manifest" in \
      *kernel*) echo "gate: core libraries present" ;; \
      *) echo "gate: ERROR image has no core/ libraries -- the build stopped before core" >&2; fail=1 ;; \
    esac; \
    if printf '%s\n' "$manifest" | grep -q '^MISSING '; then \
      echo "gate: ERROR image is missing paths a build needs:" >&2; \
      printf '%s\n' "$manifest" | grep '^MISSING ' >&2; \
      fail=1; \
    fi; \
    case "$manifest" in \
      *"build_desktop: completed"*) \
        echo "gate: the in-image build completed"; \
        case "$manifest" in \
          *"deployed_binary=/"*) echo "gate: deploy produced a binary -- this image may be packageable as-is" ;; \
          *) echo "gate: NOTE make.py returned 0 but no DesktopEditors under build_tools/out; a consuming build must still deploy" ;; \
        esac ;; \
      *) \
        echo "gate: WARNING the in-image build did NOT complete -- a consuming build will have to finish it" >&2; \
        echo "----- retained build log -----" >&2; \
        cat /var/log/lightoffice/build.tail.log >&2 2>/dev/null || echo "(no build log captured)" >&2; \
        echo "----- end -----" >&2 ;; \
    esac; \
    if [ "$fail" -ne 0 ]; then \
      echo "----- retained build log -----" >&2; \
      cat /var/log/lightoffice/build.tail.log >&2 2>/dev/null || echo "(no build log captured)" >&2; \
      echo "----- end -----" >&2; \
      exit 1; \
    fi; \
    echo "gate: image has everything a build needs"

WORKDIR /work
CMD ["/bin/bash"]
