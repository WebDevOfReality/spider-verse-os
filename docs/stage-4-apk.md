# Stage 4 — apk-tools: the OS becomes extendable

> **Provenance note:** stage notes drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from the hands-on session, 2026-09-25.

## What ships

- **`apk.static`** (5 MB, static musl + openssl 3.0.15 + zlib 1.3.1) —
  apk-tools 2.14.4 cross-compiled with *our* toolchain from source.
  Cross deps live in `toolchain/out/sysroot` (built once, gitignored):
  zlib then openssl, both `no-shared`.
- **`scripts/mkpkg.py`** — build + index commands implementing the
  apk v2 format by hand (below).
- **`apk/repo/x86_64/`** — our first repository: a busybox 1.38.0-r0
  package, signed APKINDEX, public key (`svos-key.pub`).
  `apk/svos-key.pem` is gitignored — the signing key IS the trust.
- **In-guest verification:** `apk.static --root / --allow-untrusted add
  busybox` inside a Weaver VM installs 1 MiB in 1 package. And over the
  mesh: host-b fetched the repo **via httpd on host-a through nebula0**
  (`http://10.99.99.2:8080`) and installed from it.

## The apk v2 format (reverse-engineered, receipts)

An `.apk` is **3 gzip members concatenated** (multi-member gzip —
`apk_istream_gunzip_mpart` splits on gzip-header boundaries):

1. **Signature member**: tar containing `.SIGN.RSA.<keyname>.rsa` — the
   raw RSA-SHA1 signature over **member 2's compressed bytes** (verified
   against Alpine's real package with their pub key before trusting my
   own build).
2. **Control member**: tar containing `.PKGINFO` (`pkgname = value`
   lines; `datahash = sha256(member3-compressed)`; `size = installed
   bytes`).
3. **Data member**: the payload files, **no leading `./`** (use real
   paths like `bin/busybox`, plus explicit directory entries or apk
   audit complains).

Every member is a tar **without end-of-archive zero blocks** — that's
what broke my first four attempts: GNU tar pads to a 20-block minimum,
and apk's tar parser treats those padding blocks as end-of-stream,
then chokes on the next member (`BAD archive`). `scripts/mkpkg.py`
strips trailing zero blocks explicitly.

## What we learned (the receipts)

1. **Cross-building a C project with pkg-config deps:** apk needs
   openssl+zlib in the *target* sysroot. Build zlib (`-fPIC`, needed
   later if anyone re-enables libapk.so) and openssl `no-shared` into
   `toolchain/out/sysroot`, then hand apk-tools a `config.mk` with
   `CROSS_COMPILE`, `CFLAGS/LDFLAGS` sysroot paths — its Makefile
   honors those.
2. **pkg-config on the host answers for the HOST, not the cross sysroot:**
   a 10-line `pkg-config` shim in `sysroot/bin` returning sysroot paths
   fixed the openssl/zlib link errors. Cross builds quietly lie without
   this.
3. **apk-tools Makefile quirks:** `LUA=no` (no lua on host), `LIBS_apk.static`
   needed explicit `-lssl -lcrypto -lz` (its `--as-needed` dance drops
   them otherwise), and the static link only rebuilds if `libapk.a` is
   removed — md5-identical binaries hid my debug patch for two builds.
4. **`apk index` refuses unsigned packages** (`UNTRUSTED signature`) —
   `--allow-untrusted` is for *keys you don't have*, not for packages
   without signatures. A signature made the difference.
5. **In-guest apk needs its db files pre-created** (`/etc/apk/world`,
   `/lib/apk/db/installed`) — `--initdb` exists but needs the help
   text applet which we build without (no scdoc). Hand-`touch` works.
6. **Static musl binaries and localhost http:** apk's fetch against
   `python3 -m http.server` (single-threaded) hangs on keep-alive
   connections; a `ThreadingTCPServer` works. For CI, `file://`
   repositories are the reliable path.
7. **Directory entries in the data member matter** ("no dirent in
   archive" without them) and must be `uid=0/gid=0` or apk audit errors
   on directory permissions.

## Layout

```
apk/apk.static              # cross-built static apk-tools 2.14.4
apk/svos-key.pem|pub        # signing key (pem gitignored!) + pubkey
apk/repo/x86_64/            # busybox apk + signed APKINDEX + key
scripts/mkpkg.py            # build + index the repo
toolchain/out/sysroot       # cross zlib/openssl for future C builds
```

## Honest caveats

- `--allow-untrusted` everywhere: the signature verifies only if the
  pubkey is installed; wiring `/etc/apk/keys` into the image properly
  (embedded in the squashfs/initramfs) is next.
- Packages "without embedded checksums" warning: per-file SHA1 pax
  headers (`APK-TOOLS.checksum.SHA1`, what abuild-tar emits) not yet
  implemented — datahash covers the payload for now.
- The repo in-tree is built by `mkpkg.py` from `kernel/out/rootfs`
  payloads; a `pkg/` source tree for real packages comes with Stage 5.

## Next (Stage 5 — k3s)

svos-enroll (mesh admission) + k3s agent/server inside Weaver.