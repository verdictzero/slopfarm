#!/usr/bin/env python3
"""Pull embedded textures out of a .glb, shrink them, and leave the mesh behind.

A .glb from Blender ships its PNGs *inside* the binary chunk, which is why horse.glb
is 49 MB and slopfarm_logo.glb is 63 MB even though the meshes are tiny. The game renders
at 640x360 with nearest filtering and a 512-colour palette, so 256 px is already more than
it can show (horse.glb's texture was even being clamped to 256 on import via
process/size_limit=256) — the embedded 8K originals are dead weight in the repo and in
every future commit.

This rewrites a .glb so each embedded image becomes an *external* `uri` reference to a
256 px sidecar PNG, and repacks the binary chunk with the image bytes gone. The mesh,
skin, animation and material data are preserved byte-for-byte — only bufferView indices
are remapped, because dropping the image bufferViews shifts everything after them.

Assumptions (asserted, not hoped): one buffer, no Draco/meshopt compression, no sparse
accessors. Those hold for every model in this project; the asserts fail loudly if a
future asset breaks them rather than silently corrupting geometry.

Usage:
    glb_externalize_textures.py MODEL.glb [--size 256] [--out OUT.glb] [--dry-run]

The sidecar filename matches what Godot's own "Extract Textures" import would produce
(`<glb-stem>_<image-name>.png`), so the existing <sidecar>.png.import files stay valid.
"""

import argparse
import io
import json
import os
import struct
import sys

from PIL import Image

GLB_MAGIC = 0x46546C67  # 'glTF' little-endian
CHUNK_JSON = 0x4E4F534A  # 'JSON'
CHUNK_BIN = 0x004E4942   # 'BIN\0'


def _read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, length = struct.unpack_from("<III", data, 0)
    assert magic == GLB_MAGIC, "not a .glb (bad magic)"
    assert version == 2, f"unsupported glb version {version}"
    assert length == len(data), f"header length {length} != file size {len(data)}"
    gltf = None
    binchunk = b""
    off = 12
    while off < len(data):
        clen, ctype = struct.unpack_from("<II", data, off)
        body = data[off + 8: off + 8 + clen]
        if ctype == CHUNK_JSON:
            gltf = json.loads(body.decode("utf-8"))
        elif ctype == CHUNK_BIN:
            binchunk = body
        off += 8 + clen
    assert gltf is not None, "no JSON chunk"
    return gltf, binchunk


def _bufferview_bytes(gltf, binchunk, bv_index):
    bv = gltf["bufferViews"][bv_index]
    start = bv.get("byteOffset", 0)
    return binchunk[start: start + bv["byteLength"]]


def _pad4(n):
    return (4 - (n % 4)) % 4


def _resize_png(raw, size):
    """Return (png_bytes, orig_dims, new_dims). Longest side clamped to `size`,
    aspect preserved. Square in, square out."""
    im = Image.open(io.BytesIO(raw))
    im.load()
    ow, oh = im.size
    if max(ow, oh) <= size:
        new = (ow, oh)
        out = im
    else:
        scale = size / float(max(ow, oh))
        new = (max(1, round(ow * scale)), max(1, round(oh * scale)))
        out = im.resize(new, Image.LANCZOS)
    buf = io.BytesIO()
    # optimize=True is worth the CPU here: these are committed to git.
    out.save(buf, format="PNG", optimize=True)
    return buf.getvalue(), (ow, oh), new


def externalize(path, size=256, out_path=None, dry_run=False):
    gltf, binchunk = _read_glb(path)
    stem = os.path.splitext(os.path.basename(path))[0]
    model_dir = os.path.dirname(os.path.abspath(path))

    assert len(gltf.get("buffers", [])) == 1, "expected exactly one buffer"
    assert not gltf.get("extensionsRequired"), \
        f"extensionsRequired present: {gltf['extensionsRequired']}"
    for a in gltf.get("accessors", []):
        assert "sparse" not in a, "sparse accessors not handled"

    images = gltf.get("images", [])
    embedded = [(i, im) for i, im in enumerate(images) if "bufferView" in im]
    if not embedded:
        print(f"  {stem}: no embedded images, nothing to do")
        return None

    # --- 1. extract + resize each embedded image into a sidecar PNG -------------
    image_bv = set()
    sidecars = []
    for img_index, img in embedded:
        bv = img["bufferView"]
        image_bv.add(bv)
        raw = _bufferview_bytes(gltf, binchunk, bv)
        name = img.get("name") or f"texture_{img_index}"
        sidecar_name = f"{stem}_{name}.png"
        png_bytes, odim, ndim = _resize_png(raw, size)
        sidecars.append((img_index, sidecar_name, png_bytes,
                         len(raw), odim, ndim))
        print(f"  image[{img_index}] {name!r}: {odim[0]}x{odim[1]} "
              f"{len(raw):,}B -> {ndim[0]}x{ndim[1]} {len(png_bytes):,}B "
              f"-> {sidecar_name}")

    # Two images that resolve to the same sidecar name would silently overwrite each other;
    # and a bufferView shared by an image and an accessor would be dropped out from under the
    # geometry. Neither happens in this project's assets, but fail loudly if a future one hits it.
    names = [s[1] for s in sidecars]
    assert len(set(names)) == len(names), f"sidecar filename collision among images: {names}"
    acc_bv = {a["bufferView"] for a in gltf.get("accessors", []) if "bufferView" in a}
    assert image_bv.isdisjoint(acc_bv), \
        "a bufferView is shared by an image and an accessor; dropping it would corrupt geometry"

    # --- 2. repack the binary chunk, dropping image bufferViews ----------------
    old_bvs = gltf["bufferViews"]
    keep = [i for i in range(len(old_bvs)) if i not in image_bv]
    remap = {old: new for new, old in enumerate(keep)}

    new_bin = bytearray()
    new_bvs = []
    kept_payloads = []  # (old_index, bytes) for the byte-identity check
    for old_index in keep:
        payload = _bufferview_bytes(gltf, binchunk, old_index)
        kept_payloads.append((old_index, payload))
        pad = _pad4(len(new_bin))
        new_bin.extend(b"\x00" * pad)
        offset = len(new_bin)
        new_bin.extend(payload)
        bv = dict(old_bvs[old_index])
        if len(new_bin) == offset:  # zero-length view: keep offset in range
            offset = max(0, offset - 0)
        bv["byteOffset"] = offset
        bv["byteLength"] = len(payload)
        bv["buffer"] = 0
        new_bvs.append(bv)

    # --- 3. rewire references --------------------------------------------------
    for a in gltf.get("accessors", []):
        if "bufferView" in a:
            a["bufferView"] = remap[a["bufferView"]]
    gltf["bufferViews"] = new_bvs
    for img_index, sidecar_name, *_ in sidecars:
        img = images[img_index]
        img.pop("bufferView", None)
        img["uri"] = sidecar_name
        img.setdefault("mimeType", "image/png")
    gltf["buffers"][0]["byteLength"] = len(new_bin)
    gltf["buffers"][0].pop("uri", None)

    # --- 4. assemble the new glb ----------------------------------------------
    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * _pad4(len(json_bytes))
    bin_bytes = bytes(new_bin) + b"\x00" * _pad4(len(new_bin))
    total = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)
    glb = bytearray()
    glb += struct.pack("<III", GLB_MAGIC, 2, total)
    glb += struct.pack("<II", len(json_bytes), CHUNK_JSON) + json_bytes
    glb += struct.pack("<II", len(bin_bytes), CHUNK_BIN) + bin_bytes

    # --- 5. verify before anyone trusts it ------------------------------------
    v_gltf, v_bin = _read_glb_bytes(bytes(glb))
    assert len(v_gltf["bufferViews"]) == len(keep), "bufferView count wrong"
    for old_index, payload in kept_payloads:
        got = _bufferview_bytes(v_gltf, v_bin, remap[old_index])
        assert got == payload, f"bufferView {old_index} corrupted in repack"
    for a in v_gltf.get("accessors", []):
        if "bufferView" in a:
            bv = v_gltf["bufferViews"][a["bufferView"]]
            end = bv.get("byteOffset", 0) + bv["byteLength"]
            assert end <= len(v_bin), "accessor points past bin"
    for im in v_gltf.get("images", []):
        assert "bufferView" not in im and "uri" in im, "image still embedded"

    print(f"  repacked: {os.path.getsize(path):,}B -> {len(glb):,}B "
          f"(bin {len(binchunk):,} -> {len(new_bin):,}); "
          f"bufferViews {len(old_bvs)} -> {len(new_bvs)}")

    if dry_run:
        print("  [dry-run] not writing files")
        return {"glb_bytes": bytes(glb), "sidecars": sidecars}

    for img_index, sidecar_name, png_bytes, *_ in sidecars:
        with open(os.path.join(model_dir, sidecar_name), "wb") as f:
            f.write(png_bytes)
    dest = out_path or path
    with open(dest, "wb") as f:
        f.write(glb)
    print(f"  wrote {dest} and {len(sidecars)} sidecar(s)")
    return {"glb_bytes": bytes(glb), "sidecars": sidecars}


def _read_glb_bytes(data):
    magic, version, length = struct.unpack_from("<III", data, 0)
    assert magic == GLB_MAGIC and version == 2 and length == len(data)
    gltf = None
    binchunk = b""
    off = 12
    while off < len(data):
        clen, ctype = struct.unpack_from("<II", data, off)
        body = data[off + 8: off + 8 + clen]
        if ctype == CHUNK_JSON:
            gltf = json.loads(body.decode("utf-8"))
        elif ctype == CHUNK_BIN:
            binchunk = body
        off += 8 + clen
    return gltf, binchunk


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("glb")
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--out", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    print(f"{args.glb}:")
    externalize(args.glb, size=args.size, out_path=args.out, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
