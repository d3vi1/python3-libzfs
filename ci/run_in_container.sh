#!/usr/bin/env bash
set -euo pipefail

DISTRO=${1:?distro name required}

install_common() {
  local pip_args=(--no-cache-dir)
  export PIP_BREAK_SYSTEM_PACKAGES=1
  if python3 -m pip --help 2>/dev/null | grep -q -- '--break-system-packages'; then
    pip_args+=(--break-system-packages)
  fi

  python3 -m pip install "${pip_args[@]}" cython
}

download_openzfs_headers() {
  local version=$1
  local tag="zfs-${version}"
  local url="https://github.com/openzfs/zfs/archive/refs/tags/${tag}.tar.gz"

  echo "==> Downloading OpenZFS headers ${tag}"
  mkdir -p /tmp/openzfs-src
  curl -fsSL "${url}" | tar -xz -C /tmp/openzfs-src --strip-components=1
  cp -R /tmp/openzfs-src/include/* /usr/local/include/

  export CPPFLAGS="-I/usr/local/include"
}

ensure_zfs_header() {
  local header
  if command -v rpm >/dev/null 2>&1; then
    header=$(rpm -ql libzfs5-devel 2>/dev/null | grep -m1 '/sys/fs/zfs.h$' || true)
  fi
  if [[ -z "${header}" ]]; then
    for root in /usr/include/zfs /usr/include/libzfs /usr/src /usr/local/include /usr/include /tmp/openzfs-src/include; do
      header=$(find "${root}" -path "*/sys/fs/zfs.h" -print -quit 2>/dev/null || true)
      if [[ -n "${header}" ]]; then
        break
      fi
    done
  fi
  if [[ -z "${header}" ]]; then
    echo "sys/fs/zfs.h not found after installing headers." >&2
    return 1
  fi

  local inc_root=${header%/sys/fs/zfs.h}
  export CPPFLAGS="${CPPFLAGS:-} -I${inc_root}"

  local extra
  for extra in /usr/include/libspl /usr/local/include/libspl /usr/include/libzfs /usr/local/include/libzfs; do
    if [[ -d "${extra}" ]]; then
      export CPPFLAGS="${CPPFLAGS:-} -I${extra}"
    fi
  done

  local os_linux
  os_linux=$(find /usr/src /usr/local/include /usr/include \
    -path "*/os/linux/sys/types.h" -print -quit 2>/dev/null || true)
  if [[ -n "${os_linux}" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -I${os_linux%/sys/types.h}"
  fi
  os_linux=$(find /usr/src /usr/local/include /usr/include \
    -path "*/os/linux/spl/sys/types.h" -print -quit 2>/dev/null || true)
  if [[ -n "${os_linux}" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -I${os_linux%/sys/types.h}"
  fi

  export CPPFLAGS="${CPPFLAGS:-} -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE"
}

add_pkg_config_cppflags() {
  if ! command -v pkg-config >/dev/null 2>&1; then
    return 0
  fi

  if pkg-config --exists libzfs; then
    export CPPFLAGS="${CPPFLAGS:-} $(pkg-config --cflags libzfs)"
  elif pkg-config --exists zfs; then
    export CPPFLAGS="${CPPFLAGS:-} $(pkg-config --cflags zfs)"
  fi
}

install_ubuntu_libzfs() {
  apt-get install -y --no-install-recommends ca-certificates curl

  if ! grep -Rqs "^deb .* universe" /etc/apt/sources.list /etc/apt/sources.list.d; then
    apt-get install -y --no-install-recommends software-properties-common
    add-apt-repository -y universe || true
    apt-get update
  fi

  local pkg
  for pkg in libzfs-dev libzfs4linux-dev libzfs2linux-dev; do
    if apt-get install -y --no-install-recommends "${pkg}"; then
      return
    fi
  done
  if apt-get install -y --no-install-recommends zfs-dkms; then
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
  dnf -y install dnf-plugins-core ca-certificates tar
  if ! command -v curl >/dev/null 2>&1; then
    dnf -y install curl-minimal || dnf -y --allowerasing install curl
  fi
  dnf -y install "${release_rpm}"

  dnf config-manager --set-enabled zfs || true

  if ! dnf -y --enablerepo=zfs install zfs zfs-devel; then
    if ! dnf -y --enablerepo=zfs install libzfs5 libzfs5-devel; then
      dnf -y --enablerepo=zfs install libzfs libzfs-devel
    fi
  fi

  if ! rpm -q libzfs5-devel >/dev/null 2>&1 \
    && ! rpm -q libzfs-devel >/dev/null 2>&1 \
    && ! rpm -q zfs-devel >/dev/null 2>&1; then
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
    dnf -y install gcc make python3 python3-devel python3-pip pkgconf-pkg-config \
      libblkid-devel libuuid-devel libtirpc-devel zlib-devel
    install_rocky_libzfs https://zfsonlinux.org/epel/zfs-release-2-2.el8.noarch.rpm
    ;;
  rocky-el9)
    dnf -y install gcc make python3 python3-devel python3-pip pkgconf-pkg-config \
      libblkid-devel libuuid-devel libtirpc-devel zlib-devel
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

add_pkg_config_cppflags
ensure_zfs_header
echo "==> CPPFLAGS=${CPPFLAGS:-}"
if ! CPPFLAGS="${CPPFLAGS:-}" ./configure; then
  echo "configure failed; tailing config.log" >&2
  if [[ -f config.log ]]; then
    grep -n "error:" config.log || true
    grep -n "zfs.h" config.log || true
  fi
  tail -n 200 config.log || true
  exit 1
fi
make

# Minimal import check
python3 - <<'PY'
import libzfs
print("libzfs import OK", libzfs.__name__)
PY
