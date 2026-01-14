#!/usr/bin/env bash
set -euo pipefail

DISTRO=${1:?distro name required}

install_common() {
  python3 -m pip install --no-cache-dir --upgrade pip
  python3 -m pip install --no-cache-dir cython
}

echo "==> Installing dependencies for ${DISTRO}"

case "${DISTRO}" in
  ubuntu-focal)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip \
      libzfs-dev zfsutils-linux
    ;;
  ubuntu-jammy)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip \
      libzfs-dev zfsutils-linux
    ;;
  ubuntu-questing)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip \
      libzfs-dev zfsutils-linux
    ;;
  rocky-el8)
    dnf -y install \
      gcc make python3 python3-devel python3-pip \
      libzfs-devel zfs
    ;;
  rocky-el9)
    dnf -y install \
      gcc make python3 python3-devel python3-pip \
      libzfs-devel zfs
    ;;
  *)
    echo "Unknown distro: ${DISTRO}" >&2
    exit 1
    ;;
 esac

install_common

echo "==> Build"
python3 --version

./configure
make

# Minimal import check
python3 - <<'PY'
import libzfs
print("libzfs import OK", libzfs.__name__)
PY
