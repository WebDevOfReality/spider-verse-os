#!/usr/bin/env python3
# mkpkg.py — build an Alpine-style .apk package + APKINDEX (Stage 4).
#
# Provenance: drafted with AI assistance (GLM (glm-5.3-flash) by Z.ai)
# from reverse-engineering the real apk v2 format (see docs/stage-4-apk.md).
#
# apk v2 file = 3 gzip members concatenated:
#   1. tar WITHOUT end-of-archive blocks: .SIGN.RSA.<key>.rsa  (RSA-SHA1 sig
#      over the COMPRESSED member-2 bytes)
#   2. tar WITHOUT end blocks: .PKGINFO (fields "name = value", plus
#      datahash = sha256 of member-3's compressed bytes)
#   3. tar WITHOUT end-of-archive blocks: the payload files
#
# Usage:
#   ./scripts/mkpkg.py build <name> <version> <payload-dir> <out.apk> --key <pem>
#   ./scripts/mkpkg.py index <repo-dir-with-apks> <out-APKINDEX.tar.gz> [--key <pem>]
#
# Requires: openssl CLI, python3. Signatures are verified by apk if the
# matching pubkey (svos-key.pub) is in /etc/apk/keys/.
import io
import gzip
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "apk", "repo", "x86_64")
KEY = os.path.join(HERE, "..", "apk", "svos-key")
APK_STATIC = os.path.join(HERE, "..", "apk", "apk.static")


def strip_end_blocks(raw: bytes) -> bytes:
    while len(raw) >= 512 and raw[-512:] == b"\0" * 512:
        raw = raw[:-512]
    return raw


def tar_member(entries, base, payload_dir=None):
    buf = io.BytesIO()
    tf = tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT)
    for rel in entries:
        if rel.endswith("/"):
            ti = tarfile.TarInfo(rel)
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            tf.addfile(ti)
        else:
            tf.add(os.path.join(base, rel), arcname=rel, recursive=False)
    tf.close()
    return strip_end_blocks(buf.getvalue())


def build(name, version, payload_dir, out_apk, key, pkgdesc="Spider-Verse OS package", origin=None):
    # member 3: data (payload) — dirs get entries so apk audit sees them
    entries = []
    for root, dirs, files in os.walk(payload_dir):
        rel_root = os.path.relpath(root, payload_dir)
        prefix = "" if rel_root == "." else rel_root + "/"
        for d in sorted(dirs):
            entries.append(prefix + d + "/")
        for f in sorted(files):
            entries.append(prefix + f)
    m3 = tar_member(entries, payload_dir, payload_dir)
    m3gz = gzip.compress(m3, mtime=0)
    datahash = hashlib.sha256(m3gz).hexdigest()

    size = os.path.getsize(os.path.join(payload_dir, entries[-1])) if entries else 0
    installed_size = sum(
        os.path.getsize(os.path.join(payload_dir, e))
        for e in entries
        if not e.endswith("/") and os.path.isfile(os.path.join(payload_dir, e))
    )
    with tempfile.TemporaryDirectory() as td:
        info = os.path.join(td, ".PKGINFO")
        with open(info, "w") as fh:
            fh.write(
                f"pkgname = {name}\npkgver = {version}\n"
                f"pkgdesc = {pkgdesc}\nurl = https://spider-verse.os\n"
                f"builddate = {int(time.time())}\npackager = Spider-Verse OS <weaver@spiderverse>\n"
                f"size = {installed_size}\narch = x86_64\n"
                f"origin = {origin or name}\nlicense = MIT\n"
                f"datahash = {datahash}\n"
            )
        m2 = tar_member([".PKGINFO"], td, payload_dir)
        m2gz = gzip.compress(m2, mtime=0)
        sig = os.path.join(td, "sig")
        subprocess.run(
            ["openssl", "dgst", "-sha1", "-sign", key + ".pem", "-out", sig, "/dev/stdin"],
            input=m2gz, check=True,
        )
        sigdir = os.path.join(td, "sigdir")
        os.mkdir(sigdir)
        shutil.copy(sig, os.path.join(sigdir, f".SIGN.RSA.{os.path.basename(key)}.rsa"))
        m1 = tar_member([f".SIGN.RSA.{os.path.basename(key)}.rsa"], sigdir, payload_dir)
        m1gz = gzip.compress(m1, mtime=0)
    with open(out_apk, "wb") as fh:
        fh.write(m1gz + m2gz + m3gz)
    return out_apk


def index(repo_dir, out_index, key):
    repo_dir = os.path.abspath(repo_dir)
    out_index = os.path.abspath(out_index)
    apks = sorted(f for f in os.listdir(repo_dir) if f.endswith(".apk"))
    cmd = [
        os.path.join(APK_STATIC), "index",
        "--allow-untrusted", "--no-warnings",
        "-d", "svos", "-o", out_index,
    ] + apks
    subprocess.run(cmd, check=True, cwd=repo_dir)
    return out_index


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "build":
        # build name version payload-dir out.apk --key pem
        name, version, payload, out = sys.argv[2:6]
        key = KEY
        if "--key" in sys.argv:
            key = sys.argv[sys.argv.index("--key") + 1].removesuffix(".pem")
        p = build(name, version, payload, out, key)
        print("built", p)
    elif cmd == "index":
        repo = sys.argv[2]
        out = sys.argv[3]
        index(repo, out, KEY)
        print("indexed", repo, "->", out)
    else:
        print(__doc__)
        return 1


if __name__ == "__main__":
    sys.exit(main())