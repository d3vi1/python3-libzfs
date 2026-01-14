#!/usr/bin/env bash
set -euo pipefail

DISTRO=${1:?distro name required}
STEP=${2:-all}

apt_install() {
  apt-get install -y --no-install-recommends "$@"
}

ensure_zfs_header() {
  local header=""
  if command -v rpm >/dev/null 2>&1; then
    header=$(rpm -ql libzfs5-devel 2>/dev/null | grep -m1 '/sys/fs/zfs.h$' || true)
  fi
  if [[ -z "${header}" ]]; then
    for root in /usr/local/include /usr/include /usr/include/zfs /usr/include/libzfs /tmp/openzfs-src/include /usr/src; do
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

  local ioctl_header
  ioctl_header=$(find /usr/local/include /usr/include /usr/include/zfs /usr/src \
    -path "*/sys/zfs_ioctl.h" -print -quit 2>/dev/null || true)
  if [[ -n "${ioctl_header}" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -I${ioctl_header%/sys/zfs_ioctl.h}"
  fi

  local libzfs_header
  libzfs_header=$(find /usr/local/include /usr/include /usr/include/libzfs /usr/src \
    -path "*/libzfs.h" -print -quit 2>/dev/null || true)
  if [[ -n "${libzfs_header}" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -I${libzfs_header%/libzfs.h}"
  fi

  local libspl_root
  libspl_root=$(find /usr/src -path "*/lib/libspl/include" -type d -print -quit 2>/dev/null || true)
  if [[ -n "${libspl_root}" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -I${libspl_root}"
    if [[ -d "${libspl_root}/os/linux" ]]; then
      export CPPFLAGS="${CPPFLAGS:-} -I${libspl_root}/os/linux"
    fi
  fi

  local extra
  for extra in /usr/include/libspl /usr/local/include/libspl /usr/include/libzfs /usr/local/include/libzfs; do
    if [[ -d "${extra}" ]]; then
      export CPPFLAGS="${CPPFLAGS:-} -I${extra}"
    fi
  done

  if [[ -d /usr/include/libspl || -d /usr/local/include/libspl ]]; then
    : # Prefer system libspl headers when available.
  fi

  if [[ ! -e /usr/include/sys/abd_os.h && -e /usr/include/libzpool/abd_os.h ]]; then
    mkdir -p /tmp/zfs-compat/sys
    cat > /tmp/zfs-compat/sys/abd_os.h <<'EOF'
#include <libzpool/abd_os.h>
EOF
    export CPPFLAGS="${CPPFLAGS:-} -I/tmp/zfs-compat"
  fi

  if [[ ! -e /usr/include/sys/abd_impl_os.h && -e /usr/include/libzpool/abd_impl_os.h ]]; then
    mkdir -p /tmp/zfs-compat/sys
    cat > /tmp/zfs-compat/sys/abd_impl_os.h <<'EOF'
#include <libzpool/abd_impl_os.h>
EOF
    export CPPFLAGS="${CPPFLAGS:-} -I/tmp/zfs-compat"
  fi

  export CPPFLAGS="${CPPFLAGS:-} -D_GNU_SOURCE -D_DEFAULT_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE"
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
  apt_install ca-certificates

  if ! grep -Rqs "^deb .* universe" /etc/apt/sources.list /etc/apt/sources.list.d; then
    apt_install software-properties-common
    add-apt-repository -y universe || true
    apt-get update
  fi

  local pkg
  for pkg in libzfs-dev libzfs4linux-dev libzfs2linux-dev; do
    if apt_install "${pkg}"; then
      return
    fi
  done
  if apt_install zfs-dkms; then
    return
  fi
  echo "No libzfs development package found for ${DISTRO}." >&2
  exit 1
}

install_rocky_libzfs() {
  local release_rpm=$1
  dnf -y install ca-certificates tar
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
    echo "No libzfs development package found for ${DISTRO}." >&2
    exit 1
  fi
}

echo "==> Installing dependencies for ${DISTRO}"

case "${STEP}" in
  setup|all)
    case "${DISTRO}" in
      ubuntu-focal|ubuntu-jammy|ubuntu-questing)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt_install \
          build-essential pkg-config python3 python3-dev python3-setuptools cython3 zfsutils-linux
        install_ubuntu_libzfs
        ;;
      rocky-el8)
        dnf -y install dnf-plugins-core epel-release
        dnf config-manager --set-enabled powertools || true
        dnf -y install gcc make python3 python3-devel pkgconf-pkg-config python3-Cython \
          libblkid-devel libuuid-devel libtirpc-devel zlib-devel
        install_rocky_libzfs https://zfsonlinux.org/epel/zfs-release-2-2.el8.noarch.rpm
        ;;
      rocky-el9)
        dnf -y install dnf-plugins-core epel-release
        dnf config-manager --set-enabled crb || true
        dnf -y install gcc make python3 python3-devel pkgconf-pkg-config python3-Cython \
          libblkid-devel libuuid-devel libtirpc-devel zlib-devel
        install_rocky_libzfs https://zfsonlinux.org/epel/zfs-release-2-2.el9.noarch.rpm
        ;;
      *)
        echo "Unknown distro: ${DISTRO}" >&2
        exit 1
        ;;
    esac
    ;;
esac

case "${STEP}" in
  build|all)
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
    build_dir=$(ls -d build/lib.* 2>/dev/null | head -n 1 || true)
    PYTHONPATH="${build_dir}${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import libzfs
print("libzfs import OK", libzfs.__name__)
PY
    ;;
esac
