#!/usr/bin/env python3
"""Parse a uiautomator XML dump into structured, reviewable elements.

Reads an Android `uiautomator dump` XML file and emits JSON describing every
element, with px->dp touch-target sizing, center tap coordinates, and
accessibility / "danger" heuristic flags. Standard library only.

Usage:
    inspect_ui.py DUMP.xml --density 420 [--package com.example.app]
                  [--min-dp 48] [--danger-extra "topup,wire"]

Output (stdout): a JSON object
    {
      "package": "<focused package or null>",
      "counts": {"elements": N, "clickable": N, "too_small": N,
                 "missing_desc": N, "danger": N},
      "elements": [ {element}, ... ]
    }

Each element:
    {
      "index", "class", "package", "resource_id", "text", "content_desc",
      "clickable", "enabled", "focusable", "scrollable", "long_clickable",
      "password", "bounds": [l, t, r, b], "center": [cx, cy],
      "width_px", "height_px", "width_dp", "height_dp",
      "in_package": bool,
      "flags": ["too_small", "missing_desc", "redundant_desc",
                "danger", "text_input"]  # subset present
    }
exit codes: 0 ok, 2 parse/usage error.
"""
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET

# Built-in destructive / irreversible / app-leaving action keywords. Matched
# case-insensitively as whole-ish tokens against text, content-desc and the
# resource-id leaf. Kept conservative — better to over-flag and ask than to
# silently tap something that deletes data or spends money.
DANGER_KEYWORDS = [
    "delete", "remove", "discard", "erase", "clear all", "reset", "wipe",
    "buy", "purchase", "pay", "payment", "checkout", "order", "subscribe",
    "logout", "log out", "sign out", "signout", "deactivate", "delete account",
    "send", "submit", "confirm", "post", "publish", "share", "transfer",
    "call", "dial", "uninstall", "block", "report", "unfollow", "withdraw",
]

TEXT_INPUT_CLASSES = ("EditText", "AutoCompleteTextView", "SearchView")

BOUNDS_RE = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def parse_bounds(raw):
    m = BOUNDS_RE.match(raw or "")
    if not m:
        return None
    l, t, r, b = (int(g) for g in m.groups())
    return [l, t, r, b]


def leaf_id(resource_id):
    """`com.app:id/delete_button` -> `delete button` for keyword matching."""
    if not resource_id or "/" not in resource_id:
        return resource_id or ""
    return resource_id.split("/", 1)[1].replace("_", " ")


def is_danger(text, content_desc, resource_id, keywords):
    haystack = " ".join(
        s.lower() for s in (text, content_desc, leaf_id(resource_id)) if s
    )
    return any(kw in haystack for kw in keywords)


def to_dp(px, density):
    if not density:
        return None
    return round(px / (density / 160.0), 1)


def collect(node, density, package, min_dp, keywords, out, idx=[0]):
    attr = node.attrib
    cls = attr.get("class", "")
    text = attr.get("text", "") or ""
    cdesc = attr.get("content-desc", "") or ""
    rid = attr.get("resource-id", "") or ""
    pkg = attr.get("package", "") or ""
    bounds = parse_bounds(attr.get("bounds", ""))

    def is_true(key):
        return attr.get(key, "false") == "true"

    clickable = is_true("clickable")
    long_clickable = is_true("long-clickable")
    focusable = is_true("focusable")
    enabled = attr.get("enabled", "true") == "true"
    scrollable = is_true("scrollable")
    password = is_true("password")

    width_px = height_px = cx = cy = None
    if bounds:
        l, t, r, b = bounds
        width_px, height_px = r - l, b - t
        cx, cy = (l + r) // 2, (t + b) // 2

    width_dp = to_dp(width_px, density) if width_px is not None else None
    height_dp = to_dp(height_px, density) if height_px is not None else None

    in_package = (not package) or (pkg == package)
    is_text_input = any(c in cls for c in TEXT_INPUT_CLASSES)
    # Only treat actual targets (visible, with area) as interactive.
    interactive = (clickable or long_clickable) and width_px and height_px

    flags = []
    if interactive and width_dp is not None and height_dp is not None:
        if width_dp < min_dp or height_dp < min_dp:
            flags.append("too_small")
    # An image/icon-only control that a screen reader cannot announce.
    icon_like = ("ImageView" in cls or "ImageButton" in cls)
    if (interactive or icon_like) and not text and not cdesc:
        flags.append("missing_desc")
    if text and cdesc and text.strip().lower() == cdesc.strip().lower():
        flags.append("redundant_desc")
    if (interactive or is_text_input) and is_danger(text, cdesc, rid, keywords):
        flags.append("danger")
    if is_text_input:
        flags.append("text_input")

    element = {
        "index": idx[0],
        "class": cls,
        "package": pkg,
        "resource_id": rid,
        "text": text,
        "content_desc": cdesc,
        "clickable": clickable,
        "long_clickable": long_clickable,
        "enabled": enabled,
        "focusable": focusable,
        "scrollable": scrollable,
        "password": password,
        "bounds": bounds,
        "center": [cx, cy] if cx is not None else None,
        "width_px": width_px,
        "height_px": height_px,
        "width_dp": width_dp,
        "height_dp": height_dp,
        "in_package": in_package,
        "interactive": bool(interactive),
        "is_text_input": is_text_input,
        "flags": flags,
    }
    out.append(element)
    idx[0] += 1
    for child in list(node):
        collect(child, density, package, min_dp, keywords, out, idx)


def main():
    ap = argparse.ArgumentParser(description="uiautomator XML -> element JSON")
    ap.add_argument("xml", help="path to uiautomator dump XML")
    ap.add_argument("--density", type=int, default=0,
                    help="screen density (dpi) for px->dp conversion")
    ap.add_argument("--package", default="",
                    help="target app package (marks in_package)")
    ap.add_argument("--min-dp", type=float, default=48.0,
                    help="minimum touch-target size in dp (default 48)")
    ap.add_argument("--danger-extra", default="",
                    help="comma-separated extra danger keywords")
    args = ap.parse_args()

    keywords = list(DANGER_KEYWORDS)
    keywords += [k.strip().lower() for k in args.danger_extra.split(",") if k.strip()]

    try:
        tree = ET.parse(args.xml)
    except (ET.ParseError, FileNotFoundError, OSError) as e:
        print(f"inspect_ui: cannot parse {args.xml}: {e}", file=sys.stderr)
        return 2

    root = tree.getroot()
    pkg_attr = root.attrib.get("package")
    elements = []
    for node in list(root):
        collect(node, args.density, args.package, args.min_dp, keywords, elements)

    focused_pkg = args.package or pkg_attr or None
    counts = {
        "elements": len(elements),
        "clickable": sum(1 for e in elements if e["interactive"]),
        "too_small": sum(1 for e in elements if "too_small" in e["flags"]),
        "missing_desc": sum(1 for e in elements if "missing_desc" in e["flags"]),
        "danger": sum(1 for e in elements if "danger" in e["flags"]),
    }
    json.dump(
        {"package": focused_pkg, "counts": counts, "elements": elements},
        sys.stdout, indent=2,
    )
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
