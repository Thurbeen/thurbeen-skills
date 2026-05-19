#!/usr/bin/env python3
"""Render an mxfile XML to a .drawio.png with the editable XML embedded.

Hard dep: drawio-desktop (`drawio` on PATH) plus `xvfb-run` on Linux so
the Electron app can run headless. drawio's `-e` / `--embed-diagram`
flag writes a `zTXt`/`mxGraphModel` chunk (read by app.diagrams.net),
and this script then injects a parallel `tEXt`/`mxfile` chunk so the
drawio VS Code extension can re-open the PNG as an editable diagram.

Usage: render.py <input.xml> <output.drawio.png>
"""
from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path
from urllib.parse import quote


def fail(msg: str, code: int = 1) -> None:
    print(f"render.py: {msg}", file=sys.stderr)
    sys.exit(code)


def _png_chunk(ctype: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + ctype
        + payload
        + struct.pack(">I", zlib.crc32(ctype + payload) & 0xFFFFFFFF)
    )


def inject_tEXt_mxfile(path: Path, xml: str) -> None:
    """Inject a `tEXt` chunk with keyword `mxfile` carrying the
    URL-encoded mxfile XML.

    Drawio-desktop's `-e` flag writes its own embed as
    `zTXt` / `mxGraphModel`, which app.diagrams.net accepts but
    the **drawio VS Code extension does not** — it only re-opens
    diagrams from a `tEXt` / `mxfile` chunk. We add that form too,
    matching the convention in the user-provided example.drawio.png.

    The chunk is inserted right after IHDR, before IDAT, and the
    drawio-desktop `zTXt` chunk (if any) is left in place.
    """
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")

    # Find end of IHDR (first chunk after the 8-byte signature)
    ihdr_len = struct.unpack(">I", data[8:12])[0]
    ihdr_end = 8 + 8 + ihdr_len + 4  # len + type + data + crc

    payload = b"mxfile\x00" + quote(xml).encode("latin1")
    new_chunk = _png_chunk(b"tEXt", payload)

    out = data[:ihdr_end] + new_chunk + data[ihdr_end:]
    path.write_bytes(out)


def has_mxfile_chunk(path: Path) -> bool:
    """True iff the PNG carries a `tEXt`/`mxfile` chunk — the form
    the drawio VS Code extension reads. (drawio-desktop's own
    `zTXt`/`mxGraphModel` is treated as auxiliary; we always add
    the canonical `tEXt`/`mxfile` form on top.)"""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return False
    i = 8
    while i < len(data):
        n = struct.unpack(">I", data[i : i + 4])[0]
        ctype = data[i + 4 : i + 8]
        chunk = data[i + 8 : i + 8 + n]
        if ctype == b"tEXt":
            keyword = chunk.split(b"\x00", 1)[0]
            if keyword == b"mxfile":
                return True
        if ctype == b"IEND":
            break
        i += 8 + n + 4
    return False


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        fail("usage: render.py <input.xml> <output.drawio.png>", 2)
    src = Path(argv[1]).resolve()
    dst = Path(argv[2]).resolve()
    if not src.exists():
        fail(f"input not found: {src}")
    if not dst.name.endswith(".drawio.png"):
        fail(f"output must end with .drawio.png, got: {dst.name}")
    dst.parent.mkdir(parents=True, exist_ok=True)

    drawio = shutil.which("drawio")
    if not drawio:
        fail(
            "drawio CLI not found on PATH. Install drawio-desktop:\n"
            "  https://github.com/jgraph/drawio-desktop/releases\n"
            "Debian/Ubuntu: download the .deb and `sudo dpkg -i drawio-amd64-*.deb`"
        )

    # On Linux, drawio-desktop is an Electron app that needs a display.
    # Wrap with xvfb-run for headless servers. On macOS/Windows the
    # native window manager handles this and xvfb-run isn't needed.
    cmd: list[str]
    if sys.platform.startswith("linux"):
        xvfb = shutil.which("xvfb-run")
        if not xvfb:
            fail(
                "xvfb-run not found on PATH (needed to run drawio headlessly on Linux).\n"
                "Install with: sudo apt-get install -y xvfb"
            )
        cmd = [xvfb, "-a", drawio]
    else:
        cmd = [drawio]

    cmd += [
        "--no-sandbox",
        "-x",            # export
        "-f", "png",
        "-e",            # embed editable mxfile XML (writes zTXt/mxGraphModel)
        "-o", str(dst),
        str(src),
    ]

    # drawio-desktop logs noise to stdout/stderr even on success;
    # surface it only if it actually fails.
    env = os.environ.copy()
    env.setdefault("ELECTRON_DISABLE_GPU", "1")
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        fail(f"drawio export failed (exit {proc.returncode})")

    if not dst.exists():
        fail(f"drawio reported success but output file is missing: {dst}")

    # Always inject the canonical tEXt/mxfile chunk so the diagram is
    # editable in the drawio VS Code extension (not just app.diagrams.net).
    inject_tEXt_mxfile(dst, src.read_text(encoding="utf-8"))
    if not has_mxfile_chunk(dst):
        fail(f"injected tEXt/mxfile chunk but verification failed: {dst}")

    print(str(dst))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
