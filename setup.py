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
import re
import shlex
import shutil
import tempfile
import subprocess
import sys
import sysconfig
from pathlib import Path
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
define_macros = []


def _write_config_header(root):
    config_pxi = root / 'pxd' / 'config.pxi'
    if not config_pxi.exists():
        return None

    header_lines = [
        '#ifndef PYZFS_CONFIG_H',
        '#define PYZFS_CONFIG_H',
    ]
    for line in config_pxi.read_text().splitlines():
        match = re.match(r'\s*DEF\s+(\w+)\s*=\s*([0-9]+)\s*$', line)
        if match:
            name, value = match.groups()
            header_lines.append(f'#define {name} {value}')
    header_lines.append('#endif')

    header_path = root / 'pyzfs_config.h'
    content = '\n'.join(header_lines) + '\n'
    if not header_path.exists() or header_path.read_text() != content:
        header_path.write_text(content)
    return header_path


def _parse_cython_version():
    try:
        from Cython import __version__ as cython_version
    except Exception:
        return (0, 0, 0)

    parts = re.split(r'[.+-]', cython_version)
    version = []
    for part in parts:
        if part.isdigit():
            version.append(int(part))
        else:
            break
    while len(version) < 3:
        version.append(0)
    return tuple(version[:3])


def _parse_config_defs(root):
    config_pxi = root / 'pxd' / 'config.pxi'
    if not config_pxi.exists():
        return None

    defs = {}
    for line in config_pxi.read_text().splitlines():
        match = re.match(r'\s*DEF\s+(\w+)\s*=\s*([0-9]+)\s*$', line)
        if match:
            name, value = match.groups()
            defs[name] = int(value)
    return defs


def _preprocess_cython(text, defs):
    class MissingDict(dict):
        def __missing__(self, key):
            return 0

    defs = MissingDict(defs or {})
    out_lines = []
    stack = []

    def is_active():
        return all(frame['active'] for frame in stack)

    for line in text.splitlines():
        stripped = line.lstrip()
        if not stripped:
            if is_active():
                out_lines.append(line)
            continue
        indent = len(line) - len(stripped)
        is_elif = stripped.startswith('ELIF ') and stripped.endswith(':')
        is_else = stripped == 'ELSE:'
        if is_elif or is_else:
            while stack and indent < stack[-1]['indent']:
                stack.pop()
        else:
            while stack and indent <= stack[-1]['indent']:
                stack.pop()

        if stack and stack[-1]['strip'] is None and indent > stack[-1]['indent']:
            stack[-1]['strip'] = indent - stack[-1]['indent']

        if stripped.startswith('IF ') and stripped.endswith(':'):
            expr = stripped[3:-1].strip()
            value = bool(eval(expr, {'__builtins__': {}}, defs))
            stack.append({
                'indent': indent,
                'active': value,
                'matched': value,
                'strip': None,
            })
            continue
        if is_elif:
            if not stack:
                raise ValueError('ELIF without IF')
            frame = stack[-1]
            if frame['matched']:
                frame['active'] = False
            else:
                expr = stripped[5:-1].strip()
                value = bool(eval(expr, {'__builtins__': {}}, defs))
                frame['active'] = value
                frame['matched'] = value
            continue
        if is_else:
            if not stack:
                raise ValueError('ELSE without IF')
            frame = stack[-1]
            frame['active'] = not frame['matched']
            frame['matched'] = True
            continue

        if not is_active():
            continue
        strip_total = sum(frame['strip'] or 0 for frame in stack)
        if strip_total:
            out_lines.append(line[strip_total:])
        else:
            out_lines.append(line)

    return '\n'.join(out_lines) + ('\n' if text.endswith('\n') else '')


def _prepare_cython_sources():
    if _parse_cython_version() < (3, 0, 0):
        return None

    root = Path(__file__).resolve().parent
    defs = _parse_config_defs(root)
    if defs is None:
        return None

    temp_root = Path(tempfile.mkdtemp(prefix='pyzfs-cython-'))
    shutil.copy2(root / 'libzfs.pyx', temp_root / 'libzfs.pyx')
    for name in ('nvpair.pxi', 'converter.pxi'):
        if (root / name).exists():
            shutil.copy2(root / name, temp_root / name)
    if (root / 'pxd').exists():
        shutil.copytree(root / 'pxd', temp_root / 'pxd', dirs_exist_ok=True)

    for path in temp_root.rglob('*'):
        if path.suffix not in {'.pyx', '.pxd', '.pxi'}:
            continue
        text = path.read_text()
        new = _preprocess_cython(text, defs)
        if new != text:
            path.write_text(new)

    return temp_root


project_root = Path(__file__).resolve().parent
config_header = _write_config_header(project_root)
if config_header is not None:
    extra_compile_args += ['-include', str(config_header)]
cython_src_root = _prepare_cython_sources()
pyx_source = str((cython_src_root or project_root) / 'libzfs.pyx')
cython_include_dirs = [str(project_root / 'pxd')]
if cython_src_root is not None:
    cython_include_dirs = [str(cython_src_root), str(cython_src_root / 'pxd')]

setup(
    name='libzfs',
    version='1.1',
    url='https://github.com/d3vi1/python3-libzfs',
    maintainer='python3-libzfs maintainers',
    maintainer_email='openzfs-devel@lists.openzfs.org',
    cmdclass={'build_ext': build_ext},
    ext_modules=[
        Extension(
            "libzfs",
            [pyx_source],
            libraries=libraries,
            extra_compile_args=extra_compile_args,
            define_macros=define_macros,
            cython_include_dirs=cython_include_dirs,
            extra_link_args=extra_link_args,
            library_dirs=library_dirs,
        )
    ]
)
