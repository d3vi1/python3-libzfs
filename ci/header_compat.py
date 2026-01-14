#!/usr/bin/env python3
"""Header compatibility checks for OpenZFS tags.

This validates that expected signature variants exist in libzfs.h
without requiring system libzfs packages.
"""

import argparse
import io
import os
import re
import tarfile
import urllib.request

CHECKS = {
    "zpool_add": {
        "header": "include/libzfs.h",
        "param_counts": {2, 3},
    },
    "zpool_expand_proplist": {
        "header": "include/libzfs.h",
        "param_counts": {3, 4},
    },
    "zpool_get_status": {
        "header": "include/libzfs.h",
        "param_counts": {2, 3},
        "const_param_index": 1,
    },
    "zpool_import_status": {
        "header": "include/libzfs.h",
        "param_counts": {2, 3},
        "const_param_index": 1,
    },
    "zfs_crypto_load_key": {
        "header": "include/libzfs.h",
        "param_counts": {3},
        "const_param_index": 2,
    },
    "zfs_crypto_attempt_load_keys": {
        "header": "include/libzfs.h",
        "param_counts": {2},
        "const_param_index": 1,
    },
    "zfs_foreach_mountpoint": {
        "header": "include/libzfs.h",
        "param_counts": {6},
    },
    "zpool_enable_datasets": {
        "header": "include/libzfs.h",
        "param_counts": {3, 4},
    },
    "zpool_explain_recover": {
        "header": "include/libzfs.h",
        "param_counts": {4, 6},
    },
}


def fetch_tarball(tag: str) -> bytes:
    url = f"https://github.com/openzfs/zfs/archive/refs/tags/{tag}.tar.gz"
    with urllib.request.urlopen(url) as resp:
        return resp.read()


def extract_headers(tar_bytes: bytes) -> dict:
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz") as tf:
        headers = {}
        for member in tf.getmembers():
            if not member.isfile():
                continue
            name = member.name
            # Strip top-level directory prefix
            parts = name.split("/", 1)
            if len(parts) != 2:
                continue
            relpath = parts[1]
            if relpath in {v["header"] for v in CHECKS.values()}:
                f = tf.extractfile(member)
                if f is None:
                    continue
                headers[relpath] = f.read().decode("utf-8", errors="replace")
        return headers


def find_prototypes(text: str, name: str):
    pattern = rf"\b{name}\s*\((.*?)\)\s*;"
    return re.findall(pattern, text, flags=re.S)


def split_params(param_str: str):
    params = []
    depth = 0
    current = []
    for ch in param_str:
        if ch == "(" :
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            params.append("".join(current).strip())
            current = []
            continue
        current.append(ch)
    tail = "".join(current).strip()
    if tail:
        params.append(tail)
    return params


def has_const_char_ptr(param: str) -> bool:
    return "const char" in param


def check_function(name: str, text: str, spec: dict):
    prototypes = find_prototypes(text, name)
    if not prototypes:
        raise RuntimeError(f"Missing prototype for {name}")
    valid = False
    for proto in prototypes:
        params = split_params(proto)
        if len(params) not in spec["param_counts"]:
            continue
        const_index = spec.get("const_param_index")
        if const_index is not None:
            if const_index >= len(params):
                continue
            # Accept both const and non-const for cross-version compatibility.
            if not ("char" in params[const_index]):
                continue
        valid = True
        break
    if not valid:
        raise RuntimeError(f"No compatible signature found for {name}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()

    tar_bytes = fetch_tarball(args.tag)
    headers = extract_headers(tar_bytes)

    missing_headers = {v["header"] for v in CHECKS.values()} - set(headers.keys())
    if missing_headers:
        raise RuntimeError(f"Missing headers in tarball: {', '.join(sorted(missing_headers))}")

    for name, spec in CHECKS.items():
        header = spec["header"]
        check_function(name, headers[header], spec)

    print(f"OK: {args.tag}")


if __name__ == "__main__":
    main()
