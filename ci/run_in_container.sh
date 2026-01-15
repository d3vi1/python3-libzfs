#!/usr/bin/env bash
set -euo pipefail

DISTRO=${1:?distro name required}
STEP=${2:-all}

apt_install() {
  apt-get install -y --no-install-recommends "$@"
}

apt_update() {
  apt-get -o Acquire::Retries=3 update
}

apt_has_pkg() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq "(none)"
}

enable_ubuntu_universe() {
  local list
  local updated=0
  for list in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    if [[ ! -f "${list}" ]]; then
      continue
    fi
    if grep -qE '^[^#]*\buniverse\b' "${list}"; then
      continue
    fi
    if grep -qE '^[^#]*\bmain\b' "${list}"; then
      sed -i -E '/^[^#]*\bmain\b/ { /\buniverse\b/! s/$/ universe/ }' "${list}"
      updated=1
    fi
  done
  for list in /etc/apt/sources.list.d/*.sources; do
    if [[ ! -f "${list}" ]]; then
      continue
    fi
    if grep -qE '^Components:.*\buniverse\b' "${list}"; then
      continue
    fi
    if grep -qE '^Components:.*\bmain\b' "${list}"; then
      sed -i -E '/^Components:/ { /\buniverse\b/! s/$/ universe/ }' "${list}"
      updated=1
    fi
  done
  if [[ "${updated}" -eq 1 ]]; then
    apt_update
  fi
}

enable_dpkg_docs() {
  local cfg
  for cfg in /etc/dpkg/dpkg.cfg.d/excludes /etc/dpkg/dpkg.cfg.d/docker; do
    if [[ -f "${cfg}" ]]; then
      sed -i 's/^path-exclude/#path-exclude/' "${cfg}"
      sed -i 's/^path-include/#path-include/' "${cfg}"
    fi
  done
}

ensure_python_build() {
  if python3 - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("build.__main__") else 1)
PY
  then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    if apt_has_pkg python3-build; then
      apt_install python3-build
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if dnf -q list --available python3-build >/dev/null 2>&1; then
      dnf -y install python3-build
    fi
  fi

  if python3 - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("build.__main__") else 1)
PY
  then
    return 0
  fi

  if ! python3 -m pip --version >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt_install python3-pip
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y install python3-pip
    fi
  fi

  PIP_DISABLE_PIP_VERSION_CHECK=1 \
  PIP_ROOT_USER_ACTION=ignore \
    python3 -m pip install --no-cache-dir build
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

  export PYZFS_CPPFLAGS="${CPPFLAGS:-}"
  local dpkg_flags=(-us -uc -b)
  if [[ "${DISTRO}" == "ubuntu-focal" ]]; then
    dpkg_flags+=(-d)
  fi
  (cd "${pkgroot}" && dpkg-buildpackage "${dpkg_flags[@]}")

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

build_system_packages() {
  echo "==> Build system package artifacts"
  case "${DISTRO}" in
    ubuntu-*)
      build_deb_package
      ;;
    rocky-*)
      build_rpm_package
      ;;
  esac
}

ensure_zfs_header() {
  local header=""
  if command -v rpm >/dev/null 2>&1; then
    header=$(rpm -ql libzfs5-devel 2>/dev/null | grep -m1 '/sys/fs/zfs.h$' || true)
  fi
  if [[ -z "${header}" ]]; then
    for root in /usr/local/include /usr/include /usr/include/zfs /usr/include/libzfs /usr/src; do
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

  local stdtypes_header=""
  if command -v rpm >/dev/null 2>&1; then
    stdtypes_header=$(rpm -ql libzfs5-devel libzfs-devel zfs-devel libspl-devel 2>/dev/null \
      | grep -m1 '/sys/stdtypes.h$' || true)
  elif command -v dpkg >/dev/null 2>&1; then
    stdtypes_header=$(dpkg -S "/sys/stdtypes.h" 2>/dev/null | head -n1 | awk -F': ' '{print $2}' || true)
  fi
  if [[ -z "${stdtypes_header}" ]]; then
    stdtypes_header=$(find /usr/src /usr/include /usr/local/include \
      -path "*/sys/stdtypes.h" -print -quit 2>/dev/null || true)
  fi
  if [[ -n "${stdtypes_header}" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -I${stdtypes_header%/sys/stdtypes.h}"
  fi

  if [[ -z "${libspl_root}" && -z "${stdtypes_header}" ]]; then
    mkdir -p /tmp/zfs-compat
    cat > /tmp/zfs-compat/zfs_compat.h <<'EOF'
#include <sys/types.h>
#include <stdint.h>
#include <stdarg.h>
#include <sys/mount.h>
#ifndef uchar_t
typedef unsigned char uchar_t;
#endif
#ifndef ushort_t
typedef unsigned short ushort_t;
#endif
#ifndef uint_t
typedef unsigned int uint_t;
#endif
#ifndef ulong_t
typedef unsigned long ulong_t;
#endif
#ifndef longlong_t
typedef long long longlong_t;
#endif
#ifndef u_longlong_t
typedef unsigned long long u_longlong_t;
#endif
#ifndef B_TRUE
typedef enum { B_FALSE = 0, B_TRUE = 1 } boolean_t;
#define B_FALSE 0
#define B_TRUE 1
#endif
#ifndef HAVE_HRTIME_T
typedef long long hrtime_t;
#endif
#ifndef MS_FORCE
#ifdef MNT_FORCE
#define MS_FORCE MNT_FORCE
#else
#define MS_FORCE 0
#endif
#endif
EOF
    export CPPFLAGS="${CPPFLAGS:-} -include /tmp/zfs-compat/zfs_compat.h"
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

  if [[ ! -e /usr/include/sys/zfs_ioctl.h ]]; then
    local ioctl_any=""
    if command -v rpm >/dev/null 2>&1; then
      ioctl_any=$(rpm -ql libzfs5-devel libzfs-devel zfs-devel 2>/dev/null \
        | grep -m1 'zfs_ioctl.h$' || true)
    elif command -v dpkg >/dev/null 2>&1; then
      ioctl_any=$(dpkg -S "zfs_ioctl.h" 2>/dev/null | head -n1 | awk -F': ' '{print $2}' || true)
    fi
    if [[ -z "${ioctl_any}" ]]; then
      ioctl_any=$(find /usr/local/include /usr/include /usr/include/zfs /usr/include/libzfs /usr/src \
        -name "zfs_ioctl.h" -print -quit 2>/dev/null || true)
    fi
    if [[ -n "${ioctl_any}" ]]; then
      mkdir -p /tmp/zfs-compat/sys
      cat > /tmp/zfs-compat/sys/zfs_ioctl.h <<EOF
#include "${ioctl_any}"
EOF
      export CPPFLAGS="${CPPFLAGS:-} -I/tmp/zfs-compat"
    fi
  fi

  local libshare_header
  libshare_header=$(find /usr/include /usr/local/include /usr/src \
    -name "libshare.h" -print -quit 2>/dev/null || true)
  if [[ -z "${libshare_header}" ]]; then
    mkdir -p /tmp/zfs-compat
    cat > /tmp/zfs-compat/libshare.h <<'EOF'
#ifndef LIBSHARE_H
#define LIBSHARE_H
enum sa_protocol {
	SA_PROTOCOL_NFS = 0,
	SA_PROTOCOL_SMB = 1,
	SA_NO_PROTOCOL = 255
};
#endif
EOF
    export CPPFLAGS="${CPPFLAGS:-} -I/tmp/zfs-compat"
  fi

  if [[ ! -e /usr/include/sys/mnttab.h ]]; then
    mkdir -p /tmp/zfs-compat/sys
    cat > /tmp/zfs-compat/sys/mnttab.h <<'EOF'
#ifndef _SYS_MNTTAB_H
#define _SYS_MNTTAB_H
struct mnttab {
	char *mnt_special;
	char *mnt_mountp;
	char *mnt_fstype;
	char *mnt_mntopts;
	char *mnt_time;
};
#endif
EOF
    export CPPFLAGS="${CPPFLAGS:-} -I/tmp/zfs-compat"
  fi

  if [[ ! -e /usr/include/sys/inttypes.h ]]; then
    mkdir -p /tmp/zfs-compat/sys
    cat > /tmp/zfs-compat/sys/inttypes.h <<'EOF'
#include <inttypes.h>
EOF
    export CPPFLAGS="${CPPFLAGS:-} -I/tmp/zfs-compat"
  fi

  if [[ ! -e /usr/include/sys/varargs.h ]]; then
    mkdir -p /tmp/zfs-compat/sys
    cat > /tmp/zfs-compat/sys/varargs.h <<'EOF'
#include <stdarg.h>
EOF
    export CPPFLAGS="${CPPFLAGS:-} -I/tmp/zfs-compat"
  fi

  if [[ ! -e /usr/include/ucred.h ]]; then
    mkdir -p /tmp/zfs-compat
    cat > /tmp/zfs-compat/ucred.h <<'EOF'
#ifndef _UCRED_H
#define _UCRED_H
#include <sys/types.h>
struct ucred {
	pid_t pid;
	uid_t uid;
	gid_t gid;
};
#endif
EOF
    export CPPFLAGS="${CPPFLAGS:-} -I/tmp/zfs-compat"
  fi

  export CPPFLAGS="${CPPFLAGS:-} -D_GNU_SOURCE -D_DEFAULT_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE"
}

add_pkg_config_cppflags() {
  if ! command -v pkg-config >/dev/null 2>&1; then
    return 0
  fi

  local cflags=""
  if pkg-config --exists libzfs 2>/dev/null; then
    cflags=$(pkg-config --cflags libzfs 2>/dev/null || true)
  elif pkg-config --exists zfs 2>/dev/null; then
    cflags=$(pkg-config --cflags zfs 2>/dev/null || true)
  fi
  if [[ -n "${cflags}" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} ${cflags}"
  fi
}

report_compat_stubs() {
  if [[ ! -d /tmp/zfs-compat ]]; then
    return
  fi

  local files
  if ! command -v find >/dev/null 2>&1; then
    return
  fi
  files=$(find /tmp/zfs-compat -maxdepth 2 -type f -print 2>/dev/null \
    | sed 's|^/tmp/zfs-compat/||' | sort | tr '\n' ' ' || true)
  if [[ -n "${files// }" ]]; then
    echo "==> zfs-compat stubs: ${files}"
  fi
}

dedupe_cppflags() {
  local -a args result
  local -A seen
  read -r -a args <<< "${CPPFLAGS:-}"
  for ((i=0; i<${#args[@]}; i++)); do
    local arg="${args[i]}"
    if [[ "${arg}" == "-I" || "${arg}" == "-include" || "${arg}" == "-isystem" ]]; then
      if ((i + 1 < ${#args[@]})); then
        local key="${arg} ${args[i + 1]}"
        if [[ -z "${seen[${key}]+x}" ]]; then
          result+=("${arg}" "${args[i + 1]}")
          seen["${key}"]=1
        fi
        ((i++))
        continue
      fi
    fi
    if [[ -z "${seen[${arg}]+x}" ]]; then
      result+=("${arg}")
      seen["${arg}"]=1
    fi
  done
  CPPFLAGS="${result[*]}"
  export CPPFLAGS
}

configure_quiet_flag() {
  if ./configure --help 2>/dev/null | grep -q -- '--quiet'; then
    echo "--quiet"
  fi
}

run_configure() {
  local quiet_flag
  quiet_flag=$(configure_quiet_flag)
  ./configure ${quiet_flag} >/dev/null
}

ensure_config_py() {
  if [[ -f config.py ]]; then
    return
  fi

  echo "==> Generating config.py"
  add_pkg_config_cppflags
  ensure_zfs_header
  report_compat_stubs
  echo "==> CPPFLAGS=${CPPFLAGS:-}"
  if ! run_configure; then
    echo "configure failed; tailing config.log" >&2
    if [[ -f config.log ]]; then
      grep -n "error:" config.log || true
      grep -n "zfs.h" config.log || true
    fi
    tail -n 200 config.log || true
    exit 1
  fi
}

ensure_ubuntu_runtime_libs() {
  local missing=0
  local lib
  for lib in libzfs libzfs_core libnvpair libuutil; do
    if ! find /lib /usr/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu \
      \( -name "${lib}.so*" -o -name "${lib}*linux.so*" \) -print -quit 2>/dev/null | grep -q .; then
      missing=1
    fi
  done

  if [[ "${missing}" -eq 0 ]]; then
    return
  fi

  local pkg
  for pkg in \
    libzfs6linux \
    libzfs5linux \
    libzfs4linux \
    libzfs2linux \
    libzfs1linux; do
    if apt_has_pkg "${pkg}"; then
      apt_install "${pkg}" || true
    fi
  done
  for pkg in \
    libzpool6linux \
    libzpool5linux \
    libzpool4linux \
    libzpool2linux \
    libzpool1linux; do
    if apt_has_pkg "${pkg}"; then
      apt_install "${pkg}" || true
    fi
  done
  for pkg in \
    libnvpair3linux \
    libuutil3linux \
    libnvpair1 \
    libuutil1; do
    if apt_has_pkg "${pkg}"; then
      apt_install "${pkg}" || true
    fi
  done

  local still_missing=0
  for lib in libzfs libzfs_core libnvpair libuutil; do
    if ! find /lib /usr/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu \
      \( -name "${lib}.so*" -o -name "${lib}*linux.so*" \) -print -quit 2>/dev/null | grep -q .; then
      still_missing=1
    fi
  done
  if [[ "${still_missing}" -ne 0 ]]; then
    echo "libzfs runtime libraries not found after installation." >&2
    exit 1
  fi
}

install_ubuntu_libzfs() {
  apt_install ca-certificates
  enable_ubuntu_universe

  local pkg
  for pkg in \
    libzfs-dev \
    libzfs6linux-dev \
    libzfs5linux-dev \
    libzfs5-dev \
    libzfs4linux-dev \
    libzfs4-dev \
    libzfs2linux-dev \
    libzfs2-dev; do
    if apt_has_pkg "${pkg}" && apt_install "${pkg}"; then
      if apt_has_pkg libspl-dev; then
        apt_install libspl-dev || true
      fi
      ensure_ubuntu_runtime_libs
      return
    fi
  done
  if apt_has_pkg zfs-dkms && apt_install zfs-dkms; then
    if apt_has_pkg libspl-dev; then
      apt_install libspl-dev || true
    fi
    ensure_ubuntu_runtime_libs
    return
  fi
  echo "No libzfs development package found for ${DISTRO}." >&2
  exit 1
}

install_rocky_libzfs() {
  local release_rpm=$1
  dnf -y install ca-certificates tar "${release_rpm}"

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
        enable_dpkg_docs
        apt_update
        pkgs=(
          build-essential
          pkg-config
          python3
          python3-dev
          python3-setuptools
          python3-wheel
          python3-pip
          cython3
          debhelper
          debhelper-compat
          dh-python
          dpkg-dev
          fakeroot
          python3-all
          python3-all-dev
        )
        if apt_has_pkg python3-build; then
          pkgs+=(python3-build)
        fi
        apt_install "${pkgs[@]}"
        install_ubuntu_libzfs
        ;;
      rocky-el8)
        dnf -y install dnf-plugins-core epel-release
        dnf config-manager --set-enabled powertools || true
        pkgs=(
          gcc
          make
          python3
          python3-devel
          python3-setuptools
          python3-wheel
          python3-pip
          pkgconf-pkg-config
          python3-Cython
          libblkid-devel
          libuuid-devel
          libtirpc-devel
          zlib-devel
          rpm-build
          redhat-rpm-config
          python3-jinja2
        )
        if dnf -q list --available python3-build >/dev/null 2>&1; then
          pkgs+=(python3-build)
        fi
        dnf -y install "${pkgs[@]}"
        install_rocky_libzfs https://zfsonlinux.org/epel/zfs-release-2-2.el8.noarch.rpm
        ;;
      rocky-el9)
        dnf -y install dnf-plugins-core epel-release
        dnf config-manager --set-enabled crb || true
        pkgs=(
          gcc
          make
          python3
          python3-devel
          python3-setuptools
          python3-wheel
          python3-pip
          pkgconf-pkg-config
          python3-Cython
          libblkid-devel
          libuuid-devel
          libtirpc-devel
          zlib-devel
          rpm-build
          redhat-rpm-config
          python3-jinja2
        )
        if dnf -q list --available python3-build >/dev/null 2>&1; then
          pkgs+=(python3-build)
        fi
        dnf -y install "${pkgs[@]}"
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
    report_compat_stubs
    dedupe_cppflags
    echo "==> CPPFLAGS=${CPPFLAGS:-}"
    if ! CPPFLAGS="${CPPFLAGS:-}" run_configure; then
      echo "configure failed; tailing config.log" >&2
      if [[ -f config.log ]]; then
        grep -n "error:" config.log || true
        grep -n "zfs.h" config.log || true
      fi
      tail -n 200 config.log || true
      exit 1
    fi
    export CPPFLAGS=""
    make

    # Minimal import check
    build_dir=$(ls -d build/lib.* 2>/dev/null | head -n 1 || true)
    PYTHONPATH="${build_dir}${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import libzfs
print("libzfs import OK", libzfs.__name__)
PY
    ;;
  package)
    echo "==> Package"
    add_pkg_config_cppflags
    ensure_zfs_header
    report_compat_stubs
    dedupe_cppflags
    echo "==> CPPFLAGS=${CPPFLAGS:-}"
    if ! CPPFLAGS="${CPPFLAGS:-}" run_configure; then
      echo "configure failed; tailing config.log" >&2
      if [[ -f config.log ]]; then
        grep -n "error:" config.log || true
        grep -n "zfs.h" config.log || true
      fi
      tail -n 200 config.log || true
      exit 1
    fi
    if python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 7) else 1)
PY
    then
      ensure_python_build
      python3 -m build --no-isolation --sdist --wheel
    else
      python3 setup.py sdist bdist_wheel
    fi
    build_system_packages
    ;;
esac
