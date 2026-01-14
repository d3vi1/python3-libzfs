#-
# Copyright (c) 2014 iXsystems, Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
import glob
import os
import platform
import shlex
import subprocess
import sys
import sysconfig
from collections import namedtuple
from setuptools import setup

try:
    from Cython.Distutils import build_ext
    from Cython.Distutils.extension import Extension
except ImportError:
    raise ImportError("This package requires Cython to build properly. Please install it first.")

try:
    import config
except ImportError:
    if 'build' in sys.argv or 'install' in sys.argv:
        raise ImportError('Please execute configure script first')
    else:
        config = namedtuple('config', ['CFLAGS', 'CPPFLAGS', 'LDFLAGS'])([], [], [])


libraries = ['nvpair', 'zfs', 'zfs_core', 'uutil']
if platform.system().lower() == 'freebsd':
    libraries.append('geom')

extra_link_args = list(getattr(config, 'LDFLAGS', []))
library_dirs = []


def pkg_config_libs():
    for pkg in ('libzfs', 'zfs'):
        try:
            subprocess.check_call(
                ['pkg-config', '--exists', pkg],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            continue

        try:
            output = subprocess.check_output(
                ['pkg-config', '--libs', pkg],
                universal_newlines=True,
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            continue

        libs = []
        ldflags = []
        for token in shlex.split(output):
            if token.startswith('-l'):
                libs.append(token[2:])
            else:
                ldflags.append(token)
        if libs:
            return libs, ldflags
    return None


def find_versioned_libs():
    if platform.system().lower() != 'linux':
        return None

    search_dirs = [
        '/lib',
        '/lib64',
        '/usr/lib',
        '/usr/lib64',
        '/lib/x86_64-linux-gnu',
        '/usr/lib/x86_64-linux-gnu',
    ]
    patterns = {
        'nvpair': ['libnvpair.so', 'libnvpair.so.*', 'libnvpair3linux.so*'],
        'uutil': ['libuutil.so', 'libuutil.so.*', 'libuutil3linux.so*'],
        'zfs': ['libzfs.so', 'libzfs.so.*', 'libzfs4linux.so*'],
        'zfs_core': ['libzfs_core.so', 'libzfs_core.so.*', 'libzfs_core4linux.so*'],
    }

    resolved = {}
    for key, pats in patterns.items():
        found = None
        for directory in search_dirs:
            for pat in pats:
                matches = sorted(glob.glob(os.path.join(directory, pat)))
                if matches:
                    found = matches[-1]
                    break
            if found:
                break
        if not found:
            return None
        resolved[key] = found
    return resolved


pkg = pkg_config_libs()
if pkg:
    libraries, extra_pkg_ldflags = pkg
    extra_link_args.extend(extra_pkg_ldflags)
else:
    versioned = find_versioned_libs()
    if versioned:
        libraries = []
        extra_link_args.extend(
            [versioned['nvpair'], versioned['zfs'], versioned['zfs_core'], versioned['uutil']]
        )

extra_compile_args = list(getattr(config, 'CFLAGS', [])) + list(getattr(config, 'CPPFLAGS', []))
define_macros = [('CYTHON_FALLTHROUGH', '((void)0)')]

setup(
    name='libzfs',
    version='1.1',
    cmdclass={'build_ext': build_ext},
    ext_modules=[
        Extension(
            "libzfs",
            ["libzfs.pyx"],
            libraries=libraries,
            extra_compile_args=extra_compile_args,
            define_macros=define_macros,
            cython_include_dirs=["./pxd"],
            extra_link_args=extra_link_args,
            library_dirs=library_dirs,
        )
    ]
)
