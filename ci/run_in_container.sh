#!/usr/bin/env bash
set -euo pipefail

DISTRO=${1:?distro name required}

apt_update() {
  apt-get -o Acquire::Retries=3 update
}

install_common() {
  local pip_args=(--no-cache-dir)
  export PIP_BREAK_SYSTEM_PACKAGES=1
  if python3 -m pip --help 2>/dev/null | grep -q -- '--break-system-packages'; then
    pip_args+=(--break-system-packages)
  fi

  local cython_spec="cython<3"
  if python3 - <<'PY'
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
  then
    cython_spec="cython>=3.0.11"
  fi

  python3 -m pip install "${pip_args[@]}" "${cython_spec}"
}

render_template() {
  local template=$1
  local output=$2
  local os_name=$3

  python3 - <<'PY' "${template}" "${output}" "${os_name}"
import json
import sys
from pathlib import Path
from jinja2 import Template

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
os_name = sys.argv[3]

with Path("manifest.json").open("r") as handle:
    manifest = json.load(handle)

content = Template(template_path.read_text()).render(**manifest, os_name=os_name)
output_path.write_text(content)
PY
}

build_deb_package() {
  local pkgroot
  pkgroot=$(mktemp -d /tmp/pyzfs-deb-XXXXXX)
  tar -C /work -cf - --exclude=.git --exclude=dist --exclude=build . \
    | tar -C "${pkgroot}" -xf -

  mkdir -p "${pkgroot}/debian"
  cp -a "/work/packaging/${DISTRO}/." "${pkgroot}/debian/"
  python3 - <<'PY' "${DISTRO}" "${pkgroot}/debian/control"
import json
import sys
from pathlib import Path

os_name = sys.argv[1]
output = Path(sys.argv[2])

with Path("/work/manifest.json").open("r") as handle:
    manifest = json.load(handle)

deps = manifest.get("dependencies", {}).get("ubuntu", {}).get(
    os_name, manifest.get("dependencies", {}).get("ubuntu_common", [])
)

lines = [
    f"Source: {manifest['name']}",
    "Section: utils",
    "Priority: optional",
    f"Maintainer: {manifest['author']}",
    "Build-Depends: debhelper-compat (= 13), python3-all, python3-setuptools, dh-python",
    "Standards-Version: 4.4.1",
    "X-Python3-Version: >= 3.6",
    f"Homepage: {manifest['git_url']}",
    f"Vcs-Git: {manifest['git_url']}",
    "",
    f"Package: {manifest['name']}",
    f"Architecture: {manifest['architecture']['ubuntu']}",
    f"Depends: {', '.join(deps)}",
    f"Description: {manifest['description']}",
    "",
]
output.write_text("\n".join(lines))
PY
  rm -f "${pkgroot}/debian/control.j2"
  chmod +x "${pkgroot}/debian/rules"

  (cd "${pkgroot}" && dpkg-buildpackage -us -uc -b)

  local outdir="/work/dist/packages/${DISTRO}"
  mkdir -p "${outdir}"
  find "$(dirname "${pkgroot}")" -maxdepth 1 -type f -name "*.deb" -exec cp -v {} "${outdir}/" \;
}

build_rpm_package() {
  local pkgroot
  pkgroot=$(mktemp -d /tmp/pyzfs-rpm-XXXXXX)
  mkdir -p "${pkgroot}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

  local name version
  name=$(python3 - <<'PY'
import json
with open("manifest.json", "r") as handle:
    print(json.load(handle)["name"])
PY
)
  version=$(python3 - <<'PY'
import json
with open("manifest.json", "r") as handle:
    print(json.load(handle)["version"])
PY
)

  render_template "/work/packaging/${DISTRO}/main.spec.j2" "${pkgroot}/SPECS/${name}.spec" "${DISTRO}"
  tar -C /work -czf "${pkgroot}/SOURCES/${name}-${version}.tar.gz" \
    --exclude=.git --exclude=dist --exclude=build \
    --transform "s,^,${name}-${version}/," .

  rpmbuild -ba --define "_topdir ${pkgroot}" "${pkgroot}/SPECS/${name}.spec"

  local outdir="/work/dist/packages/${DISTRO}"
  mkdir -p "${outdir}"
  find "${pkgroot}/RPMS" "${pkgroot}/SRPMS" -type f -name "*.rpm" -exec cp -v {} "${outdir}/" \;
}

download_openzfs_headers() {
  local version=$1
  local tag="zfs-${version}"
  local url="https://github.com/openzfs/zfs/archive/refs/tags/${tag}.tar.gz"

  echo "==> Downloading OpenZFS headers ${tag}"
  mkdir -p /tmp/openzfs-src
  curl -fsSL "${url}" | tar -xz -C /tmp/openzfs-src --strip-components=1

  export OPENZFS_SRC=/tmp/openzfs-src
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

  local use_openzfs_primary=0
  if [[ "${header}" == /tmp/openzfs-src/* ]]; then
    use_openzfs_primary=1
  fi

  local inc_root=${header%/sys/fs/zfs.h}
  if [[ ${use_openzfs_primary} -eq 1 ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -idirafter ${inc_root}"
  else
    export CPPFLAGS="${CPPFLAGS:-} -I${inc_root}"
  fi
  if [[ -n "${OPENZFS_SRC:-}" && -d "${OPENZFS_SRC}/include" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -idirafter ${OPENZFS_SRC}/include"
  fi

  local ioctl_header
  ioctl_header=$(find /usr/local/include /usr/include /usr/include/zfs /usr/src /tmp/openzfs-src/include \
    -path "*/sys/zfs_ioctl.h" -print -quit 2>/dev/null || true)
  if [[ -n "${ioctl_header}" ]]; then
    if [[ "${ioctl_header}" == /tmp/openzfs-src/* && ${use_openzfs_primary} -eq 1 ]]; then
      export CPPFLAGS="${CPPFLAGS:-} -idirafter ${ioctl_header%/sys/zfs_ioctl.h}"
    elif [[ "${ioctl_header}" == /tmp/openzfs-src/* && ${use_openzfs_primary} -eq 0 ]]; then
      export CPPFLAGS="${CPPFLAGS:-} -idirafter ${OPENZFS_SRC}/include"
    else
      export CPPFLAGS="${CPPFLAGS:-} -I${ioctl_header%/sys/zfs_ioctl.h}"
    fi
  fi

  local libzfs_header
  libzfs_header=$(find /usr/local/include /usr/include /usr/include/libzfs /usr/src /tmp/openzfs-src/include \
    -path "*/libzfs.h" -print -quit 2>/dev/null || true)
  if [[ -n "${libzfs_header}" ]]; then
    if [[ "${libzfs_header}" == /tmp/openzfs-src/* && ${use_openzfs_primary} -eq 1 ]]; then
      export CPPFLAGS="${CPPFLAGS:-} -idirafter ${libzfs_header%/libzfs.h}"
    else
      export CPPFLAGS="${CPPFLAGS:-} -I${libzfs_header%/libzfs.h}"
    fi
  fi

  local extra
  for extra in /usr/include/libspl /usr/local/include/libspl /usr/include/libzfs /usr/local/include/libzfs; do
    if [[ -d "${extra}" ]]; then
      export CPPFLAGS="${CPPFLAGS:-} -I${extra}"
    fi
  done

  if [[ ${use_openzfs_primary} -eq 1 && -n "${OPENZFS_SRC:-}" ]]; then
    for extra in "${OPENZFS_SRC}/include" "${OPENZFS_SRC}/lib/libzfs"; do
      if [[ -d "${extra}" ]]; then
        export CPPFLAGS="${CPPFLAGS:-} -idirafter ${extra}"
      fi
    done
    for extra in "${OPENZFS_SRC}/include/os/linux"; do
      if [[ -d "${extra}" ]]; then
        export CPPFLAGS="${CPPFLAGS:-} -idirafter ${extra}"
      fi
    done
  fi

  if [[ -d /usr/include/libspl || -d /usr/local/include/libspl ]]; then
    : # Prefer system libspl headers when available.
  elif [[ ${use_openzfs_primary} -eq 1 && -n "${OPENZFS_SRC:-}" ]]; then
    for extra in "${OPENZFS_SRC}/lib/libspl/include" "${OPENZFS_SRC}/lib/libspl/include/os/linux"; do
      if [[ -d "${extra}" ]]; then
        export CPPFLAGS="${CPPFLAGS:-} -I${extra}"
      fi
    done
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
  dnf -y install ca-certificates tar
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

  if ! find /usr/include/libzfs /usr/include -path "*/sys/zfs_ioctl.h" -print -quit 2>/dev/null | grep -q .; then
    local ver
    ver=$(rpm -q --qf '%{VERSION}' libzfs5 2>/dev/null || rpm -q --qf '%{VERSION}' zfs 2>/dev/null || true)
    if [[ -n "${ver}" ]]; then
      download_openzfs_headers "${ver}"
    fi
  fi
}

echo "==> Installing dependencies for ${DISTRO}"

case "${DISTRO}" in
  ubuntu-focal)
    export DEBIAN_FRONTEND=noninteractive
    apt_update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip python3-setuptools zfsutils-linux \
      debhelper debhelper-compat dh-python dpkg-dev fakeroot python3-all python3-all-dev python3-jinja2
    if apt-cache policy python3-cython 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq "(none)"; then
      apt-get install -y --no-install-recommends python3-cython
    fi
    install_ubuntu_libzfs
    ;;
  ubuntu-jammy)
    export DEBIAN_FRONTEND=noninteractive
    apt_update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip python3-setuptools zfsutils-linux \
      debhelper debhelper-compat dh-python dpkg-dev fakeroot python3-all python3-all-dev python3-jinja2
    if apt-cache policy python3-cython 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq "(none)"; then
      apt-get install -y --no-install-recommends python3-cython
    fi
    install_ubuntu_libzfs
    ;;
  ubuntu-questing)
    export DEBIAN_FRONTEND=noninteractive
    apt_update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-dev python3-pip python3-setuptools zfsutils-linux \
      debhelper debhelper-compat dh-python dpkg-dev fakeroot python3-all python3-all-dev python3-jinja2
    if apt-cache policy python3-cython 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq "(none)"; then
      apt-get install -y --no-install-recommends python3-cython
    fi
    install_ubuntu_libzfs
    ;;
  rocky-el8)
    dnf -y install dnf-plugins-core
    dnf config-manager --set-enabled powertools || true
    dnf -y install gcc make python3 python3-devel python3-pip pkgconf-pkg-config \
      libblkid-devel libuuid-devel libtirpc-devel zlib-devel \
      rpm-build redhat-rpm-config python3-jinja2
    install_rocky_libzfs https://zfsonlinux.org/epel/zfs-release-2-2.el8.noarch.rpm
    ;;
  rocky-el9)
    dnf -y install dnf-plugins-core
    dnf config-manager --set-enabled crb || true
    dnf -y install gcc make python3 python3-devel python3-pip pkgconf-pkg-config \
      libblkid-devel libuuid-devel libtirpc-devel zlib-devel \
      rpm-build redhat-rpm-config python3-jinja2
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
build_dir=$(ls -d build/lib.* 2>/dev/null | head -n 1 || true)
PYTHONPATH="${build_dir}${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import libzfs
print("libzfs import OK", libzfs.__name__)
PY

echo "==> Build system package artifacts"
case "${DISTRO}" in
  ubuntu-*)
    build_deb_package
    ;;
  rocky-*)
    build_rpm_package
    ;;
  *)
    echo "Skipping package build for ${DISTRO}" >&2
    ;;
esac
