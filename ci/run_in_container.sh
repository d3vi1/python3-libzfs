#!/usr/bin/env bash
set -euo pipefail

DISTRO=${1:?distro name required}

install_common() {
  local pip_args=(--no-cache-dir)
  if python3 -m pip --help 2>/dev/null | grep -q -- '--break-system-packages'; then
    pip_args+=(--break-system-packages)
  fi

  python3 -m pip install "${pip_args[@]}" --upgrade pip
  python3 -m pip install "${pip_args[@]}" cython
}

download_openzfs_headers() {
  local version=$1
  local tag="zfs-${version}"
  local url="https://github.com/openzfs/zfs/archive/refs/tags/${tag}.tar.gz"

  echo "==> Downloading OpenZFS headers ${tag}"
  mkdir -p /tmp/openzfs-src
  curl -fsSL "${url}" | tar -xz -C /tmp/openzfs-src --strip-components=1
  mkdir -p /usr/local/include/openzfs
  cp -R /tmp/openzfs-src/include/* /usr/local/include/openzfs/

  export CPPFLAGS="-I/usr/local/include/openzfs -I/usr/local/include/openzfs/sys"
}

install_ubuntu_libzfs() {
  apt-get install -y --no-install-recommends ca-certificates curl

  if apt-cache show libzfs-dev >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends libzfs-dev libzfs5
    return
  fi
  if apt-cache show libzfs4linux-dev >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends libzfs4linux-dev libzfs4linux
    return
  fi

  local ver
  ver=$(dpkg-query -W -f='${Version}' zfsutils-linux | cut -d- -f1)
  if [[ -z "${ver}" ]]; then
    echo "No libzfs development package found and cannot determine OpenZFS version." >&2
    exit 1
  fi

  download_openzfs_headers "${ver}"
}

install_rocky_libzfs() {
  local release_rpm=$1
  dnf -y install dnf-plugins-core ca-certificates curl tar
  dnf -y install "${release_rpm}"

  dnf config-manager --set-enabled zfs || true

  if ! dnf -y --enablerepo=zfs install zfs zfs-devel; then
    dnf -y --enablerepo=zfs install libzfs libzfs-devel
  fi

  if ! rpm -q libzfs-devel >/dev/null 2>&1 && ! rpm -q zfs-devel >/dev/null 2>&1; then
    local ver
    ver=$(rpm -q --qf '%{VERSION}' zfs 2>/dev/null || true)
    if [[ -n "${ver}" ]]; then
      download_openzfs_headers "${ver}"
    else
      echo "No libzfs development package found and cannot determine OpenZFS version." >&2
      exit 1
    fi
  fi
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
    install_rocky_libzfs https://zfsonlinux.org/epel/zfs-release-2-2.el8.noarch.rpm
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
