#!/usr/bin/env python3
"""Build a self-styled HTML UX/UI review report from findings + screenshots.

Reads a findings JSON and a meta JSON, draws bounding-box overlays on the
screenshots for findings that carry `bounds` (Pillow if present; skipped
gracefully otherwise), and writes `report.html` that references the PNGs in
the assets folder by relative path.

Usage:
    build_report.py FINDINGS.json --meta META.json --assets ASSETS_DIR
                    --out REPORT.html [--css report.css]

FINDINGS.json: {"findings": [ {finding}, ... ]}
  finding = {
    "screen": "screen-01", "dimension": "accessibility|visual|ux|content",
    "severity": "critical|high|medium|low|info",
    "title": str, "description": str, "recommendation": str,
    "bounds": [l,t,r,b]  # optional, in screenshot pixels
  }
META.json: {
    "app": str, "package": str, "device": str, "android": str,
    "resolution": "1080x2400", "density": 420, "date": "2026-06-04",
    "screens": [ {"id": "screen-01", "image": "screen-01.png",
                  "activity": "...", "tap_from": "..."}, ... ],
    "notes": [str, ...]   # coverage caps, skipped-danger elements, etc.
}

exit codes: 0 ok, 2 usage/IO error.
"""
import argparse
import html
import json
import os
import sys

SEVERITIES = ["critical", "high", "medium", "low", "info"]
SEV_RANK = {s: i for i, s in enumerate(SEVERITIES)}
DIMENSIONS = {
    "accessibility": "Accessibility",
    "visual": "Visual / UI",
    "ux": "UX / Navigation",
    "content": "Content / Copy",
}
# Bounding-box colors per severity (RGB) for annotation overlays.
SEV_RGB = {
    "critical": (255, 92, 92), "high": (255, 159, 67), "medium": (255, 211, 78),
    "low": (78, 201, 176), "info": (110, 168, 254),
}


def esc(s):
    return html.escape(str(s if s is not None else ""))


def annotate(assets_dir, screens, findings):
    """Draw boxes onto copies of each screenshot. Returns (annotated_map, note)."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return {}, "Pillow not installed — screenshots shown without overlays."

    by_screen = {}
    for f in findings:
        if f.get("bounds"):
            by_screen.setdefault(f["screen"], []).append(f)

    annotated = {}
    for sc in screens:
        src = os.path.join(assets_dir, sc["image"])
        if not os.path.isfile(src):
            continue
        boxes = by_screen.get(sc["id"], [])
        if not boxes:
            continue
        try:
            img = Image.open(src).convert("RGB")
        except OSError:
            continue
        draw = ImageDraw.Draw(img)
        w = max(3, img.width // 250)
        for f in boxes:
            l, t, r, b = f["bounds"]
            color = SEV_RGB.get(f.get("severity", "info"), SEV_RGB["info"])
            draw.rectangle([l, t, r, b], outline=color, width=w)
        out_name = sc["id"] + ".annotated.png"
        img.save(os.path.join(assets_dir, out_name))
        annotated[sc["id"]] = out_name
    return annotated, None


def sev_sort(findings):
    return sorted(findings, key=lambda f: SEV_RANK.get(f.get("severity"), 99))


def render_finding(f):
    sev = f.get("severity", "info")
    dim = DIMENSIONS.get(f.get("dimension", ""), f.get("dimension", ""))
    rec = f.get("recommendation", "")
    rec_html = (
        f'<div class="rec"><b>Fix:</b> {esc(rec)}</div>' if rec else ""
    )
    return f"""        <div class="finding sev-{esc(sev)}">
          <div class="row">
            <span class="badge {esc(sev)}">{esc(sev)}</span>
            <span class="tag">{esc(dim)}</span>
            <span class="title">{esc(f.get('title',''))}</span>
          </div>
          <p>{esc(f.get('description',''))}</p>
          {rec_html}
        </div>"""


def main():
    ap = argparse.ArgumentParser(description="findings + assets -> report.html")
    ap.add_argument("findings")
    ap.add_argument("--meta", required=True)
    ap.add_argument("--assets", required=True, help="assets dir (rel to report)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--css", default=None, help="path to report.css to inline")
    ap.add_argument("--pdf", default=None,
                    help="also render a PDF to this path via headless Chromium")
    args = ap.parse_args()

    try:
        with open(args.findings) as fh:
            findings = json.load(fh).get("findings", [])
        with open(args.meta) as fh:
            meta = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        print(f"build_report: {e}", file=sys.stderr)
        return 2

    css = ""
    css_path = args.css or os.path.join(os.path.dirname(__file__), "report.css")
    try:
        with open(css_path) as fh:
            css = fh.read()
    except OSError:
        css = "body{font-family:sans-serif}"

    screens = meta.get("screens", [])
    annotated, anno_note = annotate(args.assets, screens, findings)
    notes = list(meta.get("notes", []))
    if anno_note:
        notes.append(anno_note)

    # assets dir name relative to the report file (same parent expected).
    rel_assets = os.path.basename(os.path.normpath(args.assets))

    # Severity + dimension summary chips.
    sev_counts = {s: 0 for s in SEVERITIES}
    dim_counts = {d: 0 for d in DIMENSIONS}
    for f in findings:
        sev_counts[f.get("severity", "info")] = sev_counts.get(f.get("severity", "info"), 0) + 1
        if f.get("dimension") in dim_counts:
            dim_counts[f["dimension"]] += 1

    chips = "".join(
        f'<span class="chip"><span class="dot {s}"></span>{s.title()} '
        f'<b>{sev_counts.get(s,0)}</b></span>'
        for s in SEVERITIES
    )
    dim_chips = "".join(
        f'<span class="chip">{DIMENSIONS[d]} <b>{dim_counts[d]}</b></span>'
        for d in DIMENSIONS
    )

    # Per-screen sections.
    by_screen = {}
    for f in findings:
        by_screen.setdefault(f.get("screen"), []).append(f)

    screen_blocks = []
    for sc in screens:
        img_name = annotated.get(sc["id"], sc["image"])
        img_rel = f"{rel_assets}/{img_name}"
        sc_findings = sev_sort(by_screen.get(sc["id"], []))
        if sc_findings:
            findings_html = "\n".join(render_finding(f) for f in sc_findings)
        else:
            findings_html = '        <p class="empty">No findings on this screen.</p>'
        activity = sc.get("activity", "")
        tap_from = sc.get("tap_from")
        sub = esc(activity) + (f' &middot; via {esc(tap_from)}' if tap_from else "")
        screen_blocks.append(f"""      <section class="screen">
        <figure class="shot">
          <img src="{esc(img_rel)}" alt="{esc(sc['id'])}">
          <figcaption>{esc(img_name)}</figcaption>
        </figure>
        <div class="detail">
          <h3 class="screen-title">{esc(sc['id'])}</h3>
          <div class="activity">{sub}</div>
{findings_html}
        </div>
      </section>""")
    screens_html = "\n".join(screen_blocks) or '<p class="empty">No screens captured.</p>'

    # Full findings table.
    rows = []
    for f in sev_sort(findings):
        rows.append(
            f"<tr><td><span class='badge {esc(f.get('severity','info'))}'>"
            f"{esc(f.get('severity',''))}</span></td>"
            f"<td>{esc(DIMENSIONS.get(f.get('dimension',''), f.get('dimension','')))}</td>"
            f"<td>{esc(f.get('screen',''))}</td>"
            f"<td>{esc(f.get('title',''))}</td>"
            f"<td>{esc(f.get('recommendation',''))}</td></tr>"
        )
    table_html = "\n".join(rows) or "<tr><td colspan='5' class='empty'>No findings.</td></tr>"

    notes_html = ""
    if notes:
        items = "".join(f"<li>{esc(n)}</li>" for n in notes)
        notes_html = f'<h2 class="section">Coverage notes</h2><ul class="notes">{items}</ul>'

    m = lambda k: esc(meta.get(k, "—"))
    doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mobile App Review — {m('app')}</title>
<style>
{css}
</style>
</head>
<body>
<div class="wrap">
  <header class="report-head">
    <h1>Mobile App Review — {m('app')}</h1>
    <div class="meta-grid">
      <span><b>Package:</b> {m('package')}</span>
      <span><b>Device:</b> {m('device')}</span>
      <span><b>Android:</b> {m('android')}</span>
      <span><b>Resolution:</b> {m('resolution')} @ {m('density')}dpi</span>
      <span><b>Screens:</b> {len(screens)}</span>
      <span><b>Findings:</b> {len(findings)}</span>
      <span><b>Date:</b> {m('date')}</span>
    </div>
    <div class="chips">{chips}</div>
    <div class="chips">{dim_chips}</div>
  </header>

  <h2 class="section">Screens &amp; findings</h2>
{screens_html}

  <h2 class="section page-break">All findings</h2>
  <table class="findings">
    <thead><tr><th>Severity</th><th>Dimension</th><th>Screen</th><th>Title</th><th>Recommendation</th></tr></thead>
    <tbody>
{table_html}
    </tbody>
  </table>

  {notes_html}

  <footer class="report-foot">
    Generated by the <code>mobile-app-review</code> skill · Android over adb · review is heuristic + model-assisted; verify before acting.
  </footer>
</div>
</body>
</html>
"""
    try:
        with open(args.out, "w") as fh:
            fh.write(doc)
    except OSError as e:
        print(f"build_report: cannot write {args.out}: {e}", file=sys.stderr)
        return 2
    print(args.out)

    if args.pdf:
        ok = render_pdf(args.out, args.pdf)
        if ok:
            print(args.pdf)
        else:
            print("build_report: PDF step skipped (no Chromium found); HTML is "
                  "print-ready — open it and use the browser's Print > Save as PDF.",
                  file=sys.stderr)
    return 0


def render_pdf(html_path, pdf_path):
    """Render the HTML to PDF with headless Chromium. Returns True on success.

    The report CSS is print-first (@page A4, light theme, break guards), so the
    default Chromium print path produces a clean paginated PDF with no extra
    flags. A unique --user-data-dir avoids clashing with a running browser."""
    import shutil, subprocess, tempfile
    binary = next((b for b in (
        "chromium", "chromium-browser", "google-chrome",
        "google-chrome-stable", "chrome") if shutil.which(b)), None)
    if not binary:
        return False
    src = os.path.abspath(html_path)
    out = os.path.abspath(pdf_path)
    with tempfile.TemporaryDirectory(prefix="mar-chrome-") as profile:
        cmd = [
            binary, "--headless", "--no-sandbox", "--disable-gpu",
            f"--user-data-dir={profile}",
            "--no-pdf-header-footer",
            f"--print-to-pdf={out}", f"file://{src}",
        ]
        try:
            subprocess.run(cmd, check=True, capture_output=True, timeout=120)
        except (subprocess.CalledProcessError, subprocess.TimeoutError, OSError):
            return False
    return os.path.isfile(out)


if __name__ == "__main__":
    sys.exit(main())
