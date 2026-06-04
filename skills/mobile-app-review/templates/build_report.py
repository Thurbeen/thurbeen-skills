#!/usr/bin/env python3
"""Build a polished, print/PDF-first HTML UX/UI review report.

Reads a findings JSON and a meta JSON, draws bounding-box overlays on the
screenshots for findings that carry `bounds` (Pillow if present; skipped
gracefully otherwise), and writes a self-contained `report.html`: a header
with severity pills, a summary panel with stat tiles + top priorities, an
optional strategic "structural recommendations" panel, then one block per
screen pairing a phone-framed annotated screenshot with dimension-grouped,
severity-coloured observation cards, plus a full findings table and notes.

Usage:
    build_report.py FINDINGS.json --meta META.json --assets ASSETS_DIR
                    --out REPORT.html [--css report.css] [--pdf REPORT.pdf]

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
    "notes": [str, ...],            # coverage caps, skipped-danger, PII, etc.
    "summary": str,                 # optional 2-3 sentence overview
    "structural": [ {"title": str, "body": str}, ... ]  # optional strategy
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
# Bounding-box colors per severity (RGB) for annotation overlays — aligned to
# the report's severity palette (critical red ... low blue).
SEV_RGB = {
    "critical": (239, 68, 68), "high": (249, 115, 22), "medium": (245, 158, 11),
    "low": (59, 130, 246), "info": (107, 114, 128),
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
        # Draw lower-severity boxes first so critical/high sit on top.
        for f in sorted(boxes, key=lambda f: -SEV_RANK.get(f.get("severity"), 99)):
            l, t, r, b = f["bounds"]
            color = SEV_RGB.get(f.get("severity", "info"), SEV_RGB["info"])
            draw.rectangle([l, t, r, b], outline=color, width=w)
        out_name = sc["id"] + ".annotated.png"
        img.save(os.path.join(assets_dir, out_name))
        annotated[sc["id"]] = out_name
    return annotated, None


def sev_sort(findings):
    return sorted(findings, key=lambda f: SEV_RANK.get(f.get("severity"), 99))


def render_observation(f):
    sev = f.get("severity", "info")
    rec = f.get("recommendation", "")
    fix = f'<div class="obs-fix"><b>Fix:</b> {esc(rec)}</div>' if rec else ""
    return f"""          <div class="observation sev-{esc(sev)}">
            <button class="dismiss" onclick="this.parentElement.style.display='none'" title="hide">✕</button>
            <span class="badge">{esc(sev)}</span><span class="obs-title">{esc(f.get('title',''))}</span>
            <div class="obs-desc">{esc(f.get('description',''))}</div>
            {fix}
          </div>"""


def render_screen(idx, sc, annotated, rel_assets, by_screen):
    img_name = annotated.get(sc["id"], sc["image"])
    img_rel = f"{rel_assets}/{img_name}"
    items = sev_sort(by_screen.get(sc["id"], []))
    # Group findings by dimension, dimensions ordered by their worst severity.
    by_dim = {}
    for f in items:
        by_dim.setdefault(f.get("dimension", ""), []).append(f)
    dim_order = sorted(
        by_dim,
        key=lambda d: min((SEV_RANK.get(x.get("severity"), 99) for x in by_dim[d]),
                          default=99),
    )
    cats = []
    for d in dim_order:
        obs = "\n".join(render_observation(f) for f in by_dim[d])
        cats.append(
            f'        <div class="category">\n'
            f'          <div class="category-title">{esc(DIMENSIONS.get(d, d))}</div>\n'
            f'{obs}\n        </div>'
        )
    cats_html = "\n".join(cats) or '        <p class="empty">No findings on this screen.</p>'

    tap_from = sc.get("tap_from", "")
    activity = sc.get("activity", "")
    sub = esc(tap_from) + (f' &middot; {esc(activity)}' if activity else "")
    nn = f"{idx:02d}"
    return f"""    <section class="screen">
      <div class="screen-header">
        <div class="screen-number">{nn}</div>
        <div class="htext">
          <h3>{esc(sc['id'])}</h3>
          <div class="sub">{sub}</div>
        </div>
      </div>
      <div class="screen-content">
        <figure class="screenshot-wrap">
          <img src="{esc(img_rel)}" alt="{esc(sc['id'])}">
          <figcaption>{esc(img_name)}</figcaption>
        </figure>
        <div class="annotations">
{cats_html}
        </div>
      </div>
    </section>"""


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

    rel_assets = os.path.basename(os.path.normpath(args.assets))

    sev_counts = {s: sum(1 for f in findings if f.get("severity") == s) for s in SEVERITIES}
    dim_counts = {d: sum(1 for f in findings if f.get("dimension") == d) for d in DIMENSIONS}

    by_screen = {}
    for f in findings:
        by_screen.setdefault(f.get("screen"), []).append(f)

    # ---- header severity pills (only non-zero) ----
    pills = "".join(
        f'<span class="sev-pill"><span class="dot {s}"></span>{s.title()} <b>{sev_counts[s]}</b></span>'
        for s in SEVERITIES if sev_counts[s]
    )

    # ---- summary panel ----
    default_summary = (
        f"Reviewed {len(screens)} screens of {esc(meta.get('app','the app'))} "
        f"across accessibility, visual/UI, UX/navigation and content, surfacing "
        f"{len(findings)} findings. Each screenshot is annotated with "
        f"severity-coloured boxes marking the affected elements."
    )
    summary_text = esc(meta["summary"]) if meta.get("summary") else default_summary
    top = sev_sort([f for f in findings if f.get("severity") in ("critical", "high")])[:5]
    priorities = "".join(
        f'<li><strong>{f.get("severity","").upper()}</strong> · '
        f'{esc(f.get("screen",""))} — {esc(f.get("title",""))}</li>'
        for f in top
    )
    priorities_html = (
        f'<p><strong>Top priorities</strong></p><ul class="priorities">{priorities}</ul>'
        if priorities else ""
    )
    score_tiles = "".join(
        f'<div class="score-item"><div class="score-value">{dim_counts[d]}</div>'
        f'<div class="score-label">{DIMENSIONS[d]}</div></div>'
        for d in DIMENSIONS
    )
    summary_html = f"""  <div class="summary">
    <h2>Summary</h2>
    <p>{summary_text}</p>
    {priorities_html}
    <div class="scores">{score_tiles}</div>
  </div>"""

    # ---- structural recommendations panel (optional) ----
    structural_html = ""
    if meta.get("structural"):
        lis = "".join(
            f'<li><strong>{esc(s.get("title",""))}</strong> — {esc(s.get("body",""))}</li>'
            for s in meta["structural"]
        )
        structural_html = f"""  <div class="structural">
    <h2>Structural recommendations</h2>
    <ul>{lis}</ul>
  </div>"""

    # ---- per-screen blocks ----
    screen_blocks = "\n".join(
        render_screen(i + 1, sc, annotated, rel_assets, by_screen)
        for i, sc in enumerate(screens)
    ) or '<p class="empty">No screens captured.</p>'

    # ---- full findings table ----
    rows = "\n".join(
        f"<tr><td><span class='badge b-{esc(f.get('severity','info'))}'>{esc(f.get('severity',''))}</span></td>"
        f"<td>{esc(DIMENSIONS.get(f.get('dimension',''), f.get('dimension','')))}</td>"
        f"<td>{esc(f.get('screen',''))}</td>"
        f"<td>{esc(f.get('title',''))}</td>"
        f"<td>{esc(f.get('recommendation',''))}</td></tr>"
        for f in sev_sort(findings)
    ) or "<tr><td colspan='5' class='empty'>No findings.</td></tr>"

    notes_html = ""
    if notes:
        items = "".join(f"<li>{esc(n)}</li>" for n in notes)
        notes_html = f'<h2 class="section">Coverage &amp; notes</h2><ul class="notes">{items}</ul>'

    m = lambda k: esc(meta.get(k, "—"))
    meta_line = (
        f"{m('date')} &middot; {len(screens)} screens &middot; {len(findings)} findings "
        f"&middot; {m('device')} &middot; Android {m('android')} &middot; "
        f"{m('resolution')} @ {m('density')}dpi &middot; <code>{m('package')}</code>"
    )

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
<div class="container">
  <header class="report-head">
    <h1>Mobile App Review — {m('app')}</h1>
    <p class="meta">{meta_line}</p>
    <div class="sev-pills">{pills}</div>
  </header>

{summary_html}

{structural_html}

  <h2 class="section">Screens &amp; findings</h2>
{screen_blocks}

  <h2 class="section page-break">All findings</h2>
  <table class="findings">
    <thead><tr><th>Severity</th><th>Dimension</th><th>Screen</th><th>Title</th><th>Recommendation</th></tr></thead>
    <tbody>
{rows}
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
