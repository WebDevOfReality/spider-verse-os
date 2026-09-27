#!/usr/bin/env python3
# registry.py — minimal Docker Registry v2 (pull-only, HTTP, no TLS).
#
# Purpose: let the Weaver VM's containerd pull images from the host over
# slirp without Docker Hub TLS/DNS pain. Serves a pre-seeded image tree:
#
#   registry/
#     pause-manifest.json     # the manifest LIST (tag 3.10.2 -> amd64)
#     pause-amd64.json        # the amd64 manifest
#     pause-config.json       # the config blob
#     pause-layer.tar.gz      # the layer blob
#
# Endpoints containerd needs (pull path only):
#   GET/HEAD /v2/                                   -> 200 (api version check)
#   GET/HEAD /v2/<name>/manifests/<tag|digest>
#   GET/HEAD /v2/<name>/blobs/<digest>
#
# Every object is addressed by the sha256 of its bytes, computed at startup,
# and every response carries THAT digest in Docker-Content-Digest.
# containerd trusts the header when it resolves a tag: if the tag's digest
# names a different object, the next fetch comes back the wrong size
# ("short read: expected 2261 bytes but got 0").
#
# Usage: python3 scripts/registry.py [port]   (default 5000, binds 127.0.0.1)
#
# Point the guest at it via /etc/rancher/k3s/registries.yaml:
#   mirrors:
#     docker.io:
#       endpoint: ["http://10.0.2.2:5000"]
# (10.0.2.2 = slirp gateway = host). Agent restart picks it up.
#
# Provenance: drafted with AI assistance (GLM (glm-5.3-flash) by Z.ai);
# digest handling rewritten with Claude (Opus 5.5) after the guest pull
# failed on a mismatched Docker-Content-Digest. Digests verified against
# Docker Hub at fetch time.
import hashlib
import http.server
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.join(HERE, "..", "registry")

REPO = "rancher/mirrored-pause"
TAG = "3.10.2"

MANIFEST_LIST = "application/vnd.docker.distribution.manifest.list.v2+json"
MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
BLOB = "application/octet-stream"

# file -> media type; the tag points at the manifest list
FILES = {
    "pause-manifest.json": MANIFEST_LIST,
    "pause-amd64.json": MANIFEST,
    "pause-config.json": BLOB,
    "pause-layer.tar.gz": BLOB,
}


def load():
    """Read every object once; index it by the sha256 of its bytes."""
    objects = {}
    for name, ctype in FILES.items():
        body = open(os.path.join(STORE, name), "rb").read()
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        objects[digest] = (body, ctype)
        if ctype == MANIFEST_LIST:
            tag_digest = digest
    return objects, tag_digest


OBJECTS, TAG_DIGEST = load()


class Registry(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, body, ctype, digest=None, code=200, head_only=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Docker-Distribution-API-Version", "registry/2.0")
        if digest:
            self.send_header("Docker-Content-Digest", digest)
        self.end_headers()
        # HEAD gets headers only: stray body bytes on a keep-alive
        # connection would be read as the start of the next response
        if not head_only:
            self.wfile.write(body)

    def _not_found(self, code_name, head_only):
        err = json.dumps({"errors": [{"code": code_name,
                                      "message": "not found"}]}).encode()
        self._send(err, "application/json", code=404, head_only=head_only)

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only=False):
        path = self.path.split("?")[0]
        if path == "/v2/":
            self._send(b"{}", "application/json", head_only=head_only)
            return

        # /v2/<repo>/(manifests|blobs)/<ref>; the repo name contains a slash
        prefix = "/v2/" + REPO + "/"
        if not path.startswith(prefix):
            self._not_found("NAME_UNKNOWN", head_only)
            return
        kind, _, ref = path[len(prefix):].partition("/")

        if kind == "manifests":
            digest = TAG_DIGEST if ref == TAG else ref
            obj = OBJECTS.get(digest)
            if obj and obj[1] in (MANIFEST_LIST, MANIFEST):
                self._send(obj[0], obj[1], digest, head_only=head_only)
            else:
                self._not_found("MANIFEST_UNKNOWN", head_only)
            return

        if kind == "blobs":
            obj = OBJECTS.get(ref)
            if obj:
                self._send(obj[0], BLOB, ref, head_only=head_only)
            else:
                self._not_found("BLOB_UNKNOWN", head_only)
            return

        self._not_found("UNSUPPORTED", head_only)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Registry)
    print(f"registry serving {REPO}:{TAG} ({TAG_DIGEST}) on 127.0.0.1:{port}")
    for digest, (body, ctype) in OBJECTS.items():
        print(f"  {digest}  {len(body):>7}  {ctype}")
    srv.serve_forever()
