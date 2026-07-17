#!/usr/bin/env python3
"""Fetch the Godot 4.7 editor binary and Android/Linux export templates.

Godot is distributed only from github.com, which this environment's egress policy
blocks (403 from the agent proxy). Docker Hub is reachable, though, and the
`barichello/godot-ci` image bundles the exact same official binary plus the
export templates. So we pull them straight out of the image's layers over the
registry HTTP API — no docker daemon needed (it isn't running here anyway).

Everything lands in a stable path so the container-state cache keeps it across
sessions; the script is idempotent and exits early if the files are already there.
"""

import os
import shutil
import ssl
import sys
import tarfile
import urllib.request

REPO = os.environ.get("GODOT_CI_REPO", "barichello/godot-ci")
TAG = os.environ.get("GODOT_CI_TAG", "4.7")
GODOT_VERSION = os.environ.get("GODOT_VERSION", "4.7")
GODOT_DIR = os.environ.get("GODOT_DIR", "/opt/godot")
# Godot looks templates up under <data>/godot/export_templates/<version>.<status>.
TEMPLATES_DIR = os.environ.get(
    "GODOT_TEMPLATES_DIR",
    "/root/.local/share/godot/export_templates/%s.stable" % GODOT_VERSION)

CA = "/root/.ccr/ca-bundle.crt"
BINARY_MEMBER = "usr/local/bin/godot"
# Template basenames worth keeping: Android (the point of this exercise) and Linux
# (so exports can be smoke-tested locally). The rest of the platforms are skipped
# to save disk — the layer carries every platform.
TEMPLATE_KEEP = {
    "android_debug.apk", "android_release.apk", "android_source.zip",
    "linux_debug.x86_64", "linux_release.x86_64",
    "linux_debug.arm64", "linux_release.arm64",
}


def _opener():
    ctx = ssl.create_default_context(cafile=CA) if os.path.exists(CA) else None
    handlers = []
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
    if ctx is not None:
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    return urllib.request.build_opener(*handlers)


OP = _opener()


def _token():
    import json
    url = ("https://auth.docker.io/token?service=registry.docker.io"
           "&scope=repository:%s:pull" % REPO)
    return json.load(OP.open(url, timeout=60))["token"]


def _manifest(token):
    import json
    accept = ("application/vnd.docker.distribution.manifest.v2+json,"
              "application/vnd.oci.image.manifest.v1+json,"
              "application/vnd.docker.distribution.manifest.list.v2+json,"
              "application/vnd.oci.image.index.v1+json")
    req = urllib.request.Request(
        "https://registry-1.docker.io/v2/%s/manifests/%s" % (REPO, TAG),
        headers={"Authorization": "Bearer " + token, "Accept": accept})
    m = json.load(OP.open(req, timeout=60))
    if "manifests" in m:  # multi-arch index → resolve amd64
        amd = next(x for x in m["manifests"]
                   if x.get("platform", {}).get("architecture") == "amd64")
        req = urllib.request.Request(
            "https://registry-1.docker.io/v2/%s/manifests/%s" % (REPO, amd["digest"]),
            headers={"Authorization": "Bearer " + token, "Accept": accept})
        m = json.load(OP.open(req, timeout=60))
    return m


def _blob(digest, token):
    req = urllib.request.Request(
        "https://registry-1.docker.io/v2/%s/blobs/%s" % (REPO, digest),
        headers={"Authorization": "Bearer " + token})
    return OP.open(req, timeout=600)


def _already_installed():
    if not os.path.exists(os.path.join(GODOT_DIR, "godot")):
        return False
    return os.path.exists(os.path.join(TEMPLATES_DIR, "android_release.apk"))


def _extract_from_layer(digest, token, targets):
    """Stream one gzipped layer and pull out the members we still need.

    Returns the set of target keys still missing after this layer. The binary
    sits after the templates in the tar, so a single pass over the big layer
    yields both; we stop as soon as nothing is left to find.
    """
    resp = _blob(digest, token)
    tf = tarfile.open(fileobj=resp, mode="r|gz")
    for member in tf:
        if not targets:
            break
        name = member.name.lstrip("./")
        base = os.path.basename(name)
        if name == BINARY_MEMBER and "binary" in targets:
            dest = os.path.join(GODOT_DIR, "godot")
            os.makedirs(GODOT_DIR, exist_ok=True)
            src = tf.extractfile(member)
            with open(dest, "wb") as out:
                shutil.copyfileobj(src, out, length=4 << 20)
            os.chmod(dest, 0o755)
            targets.discard("binary")
            print("  + godot binary -> %s" % dest, flush=True)
        elif "export_templates/" in name and base in TEMPLATE_KEEP:
            dest = os.path.join(TEMPLATES_DIR, base)
            os.makedirs(TEMPLATES_DIR, exist_ok=True)
            src = tf.extractfile(member)
            if src is not None:
                with open(dest, "wb") as out:
                    shutil.copyfileobj(src, out, length=4 << 20)
                targets.discard("tmpl:" + base)
                print("  + template %s" % base, flush=True)
    try:
        tf.close()
    except Exception:
        pass
    return targets


def main():
    if _already_installed():
        print("godot already present at %s — skipping" % GODOT_DIR)
        return 0

    token = _token()
    manifest = _manifest(token)
    layers = manifest["layers"]
    # Largest layer first: the godot binary + templates live in the big one, so
    # this normally needs a single layer download.
    order = sorted(range(len(layers)), key=lambda i: layers[i]["size"], reverse=True)

    targets = {"binary"} | {"tmpl:" + b for b in TEMPLATE_KEEP}
    # Only the debug/release apks and android_source are strictly required; treat
    # the rest as best-effort so a missing platform file does not block install.
    required = {"binary", "tmpl:android_debug.apk", "tmpl:android_release.apk",
                "tmpl:android_source.zip"}

    last_err = None
    for attempt in range(3):
        try:
            remaining = set(targets)
            for i in order:
                if not (remaining & required) and "binary" not in remaining:
                    break
                size_mb = layers[i]["size"] / 1e6
                if size_mb < 1.0:
                    continue
                print("scanning layer %d (%.0f MB)..." % (i, size_mb), flush=True)
                remaining = _extract_from_layer(layers[i]["digest"], token, remaining)
                if not (remaining & required):
                    break
            missing_required = remaining & required
            if missing_required:
                raise RuntimeError("did not find required members: %s" % missing_required)
            print("godot install complete")
            return 0
        except Exception as exc:  # noqa: BLE001 — retry any network/parse failure
            last_err = exc
            print("attempt %d failed: %s" % (attempt + 1, exc), flush=True)
            token = _token()
    print("ERROR: could not fetch godot: %s" % last_err, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
