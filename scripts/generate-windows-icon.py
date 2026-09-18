#!/usr/bin/env python3
"""Wrap existing PNG iconset images in ICO; no external imaging dependency."""
import pathlib
import struct
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
images = [(size, (source / f"icon_{size}x{size}.png").read_bytes()) for size in (16, 32, 128, 256)]
offset = 6 + 16 * len(images)
entries = []
for size, data in images:
    entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
    offset += len(data)
target.write_bytes(struct.pack("<HHH", 0, 1, len(images)) + b"".join(entries) + b"".join(data for _, data in images))
