#!/usr/bin/env bash
set -euo pipefail

DISTRO=${1:?distro name required}

install_common() {
  python3 -m pip install --no-cache-dir --upgrade pip
  python3 -m pip install --no-cache-dir cython
}

install_ubuntu_libzfs() {
  if apt-cache show libzfs-dev >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends libzfs-dev libzfs5
    return
  fi
  if apt-cache show libzfs4linux-dev >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends libzfs4linux-dev libzfs4linux
    return
  fi
  echo "No libzfs development package found for this Ubuntu release." >&2
  exit 1
}

install_rocky_libzfs() {
  local release_rpm=$1
  dnf -y install dnf-plugins-core ca-certificates curl
  dnf -y install "${release_rpm}"
  dnf -y install libzfs libzfs-devel
}

echo "==> Installing dependencies for ${DISTRO}"

case "${DISTRO}" in
  ubuntu-focal)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip zfsutils-linux
    install_ubuntu_libzfs
    ;;
  ubuntu-jammy)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip zfsutils-linux
    install_ubuntu_libzfs
    ;;
  ubuntu-questing)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip zfsutils-linux
    install_ubuntu_libzfs
    ;;
  rocky-el8)
    dnf -y install gcc make python3 python3-devel python3-pip
    install_rocky_libzfs https://zfsonlinux.org/epel/zfs-release-2-1.el8.noarch.rpm
    ;;
  rocky-el9)
    dnf -y install gcc make python3 python3-devel python3-pip
    install_rocky_libzfs https://zfsonlinux.org/epel/zfs-release-2-2.el9.noarch.rpm
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
