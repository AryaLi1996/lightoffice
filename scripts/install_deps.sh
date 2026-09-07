#!/usr/bin/env bash
#
# Install the tools the acceptance checks need.
#
# Idempotent and safe to run repeatedly: each tool is probed first, so a second
# run installs nothing. Anything already present is left alone rather than
# reinstalled, which keeps this usable on a developer machine as well as a
# clean CI runner.
#
# Usage: scripts/install_deps.sh [--check]
#   --check  report what is missing and exit non-zero, install nothing

set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# command -> apt package providing it
declare -A APT=(
  [jq]=jq
  [identify]=imagemagick
  [pngcrush]=pngcrush
  [optipng]=optipng
  [curl]=curl
  [grep]=grep
  [awk]=gawk
  [sha256sum]=coreutils
  [inotifywait]=inotify-tools
  [shellcheck]=shellcheck
  [7z]=p7zip-full
  [xdotool]=xdotool
  [openssl]=openssl
)

missing=()
for cmd in "${!APT[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

# /usr/bin/time is a distinct binary from the shell builtin; the RSS baseline
# needs the former, so probe the path rather than the name.
[ -x /usr/bin/time ] || missing+=(time)

# These are not apt packages.
command -v docker  >/dev/null 2>&1 || missing+=(docker)
command -v node    >/dev/null 2>&1 || missing+=(node)
command -v svgo    >/dev/null 2>&1 || missing+=(svgo)
command -v cfn-lint >/dev/null 2>&1 || missing+=(cfn-lint)

if [ ${#missing[@]} -eq 0 ]; then
  echo "all required tools present"
  exit 0
fi

echo "missing: ${missing[*]}"
if [ "$CHECK_ONLY" -eq 1 ]; then
  exit 1
fi

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null; then
  echo "need root or sudo to install" >&2
  exit 1
fi
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo

apt_pkgs=()
for m in "${missing[@]}"; do
  [ -n "${APT[$m]:-}" ] && apt_pkgs+=("${APT[$m]}")
  [ "$m" = "time" ] && apt_pkgs+=(time)
done

if [ ${#apt_pkgs[@]} -gt 0 ]; then
  echo "apt: ${apt_pkgs[*]}"
  $SUDO apt-get update -qq
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "${apt_pkgs[@]}"
fi

printf '%s\n' "${missing[@]}" | grep -qx svgo     && $SUDO npm install -g svgo
printf '%s\n' "${missing[@]}" | grep -qx cfn-lint && pip3 install --quiet --break-system-packages cfn-lint

# Docker and Node are deliberately not auto-installed: both have several valid
# installation methods (distro package, upstream repo, version manager) and
# picking one silently would fight whatever the host already uses.
for t in docker node; do
  printf '%s\n' "${missing[@]}" | grep -qx "$t" && \
    echo "NOTE: $t must be installed manually — see docs/DEVELOPER_GUIDE.md"
done

echo
"$0" --check
