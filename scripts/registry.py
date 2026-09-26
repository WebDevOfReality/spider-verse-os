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
#   HEAD     /v2/<name>/manifests/<ref>             (digest, content-type)
#   GET      /v2/<name>/manifests/<ref>
#   GET/HEAD /v2/<name>/blobs/<digest>
#   GET      /v2/<name>/blobs/uploads/<uuid>        (for HEAD-able blobs, rarely hit)
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
# digests verified against Docker Hub at fetch time.
import hashlib
import http.server
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.join(HERE, "..", "registry")

MANIFEST_LIST = open(os.path.join(STORE, "pause-manifest.json"), "rb").read()
MANIFEST_AMD = open(os.path.join(STORE, "pause-amd64.json"), "rb")
CONFIG = open(os.path.join(STORE, "pause-config.json"), "rb").read()
LAYER = open(os.path.join(STORE, "pause-layer.tar.gz"), "rb")

AMD_DIGEST = "sha256:" + hashlib.sha256(
    open(os.path.join(STORE, "pause-amd64.json"), "rb").read()
).hexdigest()

REPO = "rancher/mirrored-pause"
TAG = "3.10.2"


class Registry(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, body, ctype, code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Docker-Content-Digest", AMD_DIGEST)
        self.end_headers()
        self.wfile.write(body)

    def _not_found(self):
        err = json.dumps({"errors": [{"code": "MANIFEST_UNKNOWN",
                                      "message": "not found"}]}).encode()
        self._send(err, "application/json", 404)

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only=False):
        path = self.path.split("?")[0]
        if path == "/v2/":
            self._send(b"{}", "application/json")
            return

        if not path.startswith("/v2/"):
            self._not_found()
            return

        parts = path.split("/")
        parts = path.split("/")
        # /v2/rancher/mirrored-pause/manifests/<ref> -> 6 parts (repo has a slash)
        if len(parts) == 6 and parts[1] == "v2" and parts[2] == "rancher" and parts[3] == "mirrored-pause" and parts[4] == "manifests":
            ref = parts[5]
            if ref == TAG:
                self._send(open(os.path.join(STORE, "pause-manifest.json"), "rb").read(),
                           "application/vnd.docker.distribution.manifest.list.v2+json")
            elif ref == AMD_DIGEST or ref.startswith("sha256:412c"):
                body = MANIFEST_AMD.read()
                MANIFEST_AMD.seek(0)
                self._send(body, "application/vnd.docker.distribution.manifest.v2+json")
            else:
                self._not_found()
            return

        # /v2/rancher/mirrored-pause/blobs/<digest> -> 6 parts
        if len(parts) == 6 and parts[1] == "v2" and parts[2] == "rancher" and parts[3] == "mirrored-pause" and parts[4] == "blobs":
            digest = parts[5]
            if "4a83b15d" in digest:
                self._send(open(os.path.join(STORE, "pause-config.json"), "rb").read(),
                           "application/octet-stream")
            elif "81ede362" in digest:
                body = open(os.path.join(STORE, "pause-layer.tar.gz"), "rb").read()
                ctype = "application/octet-stream"
                if head_only:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Docker-Content-Digest", digest)
                    self.end_headers()
                    return
                self._send(body, ctype)
            else:
                self._not_found()
            return

        self._not_found()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Registry)
    print(f"registry serving {REPO}:{TAG} on 127.0.0.1:{port}")
    srv.serve_forever()