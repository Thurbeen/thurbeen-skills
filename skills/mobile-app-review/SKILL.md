---
name: mobile-app-review
description: Review the design, UX, UI, accessibility, and content of a running Android app over adb. Auto-explores screens with safety guardrails and approval before risky actions, then produces a print/PDF-ready HTML report (with optional one-step PDF export) with annotated screenshots and findings.
user-invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

## Mobile App Review

Drive a running **Android** app over **adb**, capture each screen
(screenshot + UI hierarchy), review it across four dimensions —
**accessibility, visual/UI design, UX/navigation, content/copy** —
and emit a styled **`report.html`** with **annotated screenshots** and
structured findings.

**Input:** `$ARGUMENTS` may name the target app (`package` or a fuzzy
app name) and/or an output dir. All optional — defaults are resolved in
Phase 0.

**Output:** a directory containing `report.html` (print/PDF-first — a
light, paginated document layout), an optional `report.pdf`, an
`assets/` folder (raw + annotated PNGs and the raw `uiautomator` XML),
`findings.json`, and `meta.json`.

**Platform:** Android only. iOS is out of scope (this skill relies on
`adb`). If the user asks for iOS, say so and stop.

**Safety model:** exploration is automated but **guardrailed** — it
stays inside the target package, detects loops, caps how far it walks,
and **asks for approval before tapping anything that looks destructive
or irreversible** (delete / buy / pay / logout / send / share / …).
It never types into text fields unless the user approves a specific
value. Treat this as a review tool, not a test runner: prefer a
disposable account / emulator.

### How this skill works

A single `SKILL.md` you execute with native tools, plus two deterministic
helpers under `templates/`:

- `inspect_ui.py` — parses a `uiautomator` XML dump into element JSON
  with px→dp touch-target sizing, center tap coordinates, and
  accessibility / danger flags.
- `build_report.py` — turns `findings.json` + `meta.json` + the
  screenshots into `report.html`, drawing severity-colored bounding
  boxes on flagged elements (Pillow if available, skipped gracefully).
  The HTML uses a print/PDF-first stylesheet (light theme, `@page` A4,
  `break-inside` guards so findings never split across pages). Pass
  `--pdf <path>` to also emit a PDF via headless Chromium in one step.

Resolve the skill dir once so the helpers are reachable through the
symlink:

```bash
SKILL_DIR="$(dirname "$(readlink -f "$HOME/.claude/skills/mobile-app-review")")/mobile-app-review"
```

---

### Setup — config

Read optional keys under `mobile-app-review` from `.claude/config.yaml`
in the current repo. All have defaults; a missing file is fine.

```bash
CFG=.claude/config.yaml
PACKAGE="$(yq      -r '.["mobile-app-review"].package        // ""'   "$CFG" 2>/dev/null)"
MAX_SCREENS="$(yq  -r '.["mobile-app-review"].max_screens    // 15'   "$CFG" 2>/dev/null)"
MAX_DEPTH="$(yq    -r '.["mobile-app-review"].max_depth      // 4'    "$CFG" 2>/dev/null)"
OUTPUT_DIR="$(yq   -r '.["mobile-app-review"].output_dir     // ""'   "$CFG" 2>/dev/null)"
MIN_DP="$(yq       -r '.["mobile-app-review"].min_touch_target_dp // 48' "$CFG" 2>/dev/null)"
DANGER_EXTRA="$(yq -r '.["mobile-app-review"].danger_keywords // [] | join(",")' "$CFG" 2>/dev/null)"
DEVICE_SERIAL="$(yq -r '.["mobile-app-review"].device_serial // ""'   "$CFG" 2>/dev/null)"
```

`$ARGUMENTS` overrides config: a token that looks like a package
(`com.foo.bar`) sets `PACKAGE`; a path-like token sets `OUTPUT_DIR`.

Default `OUTPUT_DIR` to a timestamped dir so reruns don't clobber:

```bash
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="./mobile-app-review-report/$(date +%Y%m%d-%H%M%S)"
```

Use `ADB="adb${DEVICE_SERIAL:+ -s $DEVICE_SERIAL}"` as the adb prefix
throughout.

---

### Phase 0 — Pre-flight

1. **adb present & working.**

   ```bash
   adb version
   ```

   If this fails with `libprotobuf.so` missing (a known Arch quirk),
   stop and tell the user: install the matching `libprotobuf` /
   `android-tools` package, then rerun. Do not proceed without a
   working adb.

2. **Exactly one device.**

   ```bash
   adb devices -l
   ```

   - Zero devices → stop: "Connect a device (USB debugging on) or start
     an emulator, then rerun."
   - More than one and no `DEVICE_SERIAL` → list them and ask which via
     AskUserQuestion, then set `DEVICE_SERIAL`.

3. **Device metadata** (store for `meta.json`):

   ```bash
   $ADB shell wm size                              # -> Physical size: 1080x2400
   $ADB shell wm density                           # -> Physical density: 420
   $ADB shell getprop ro.build.version.release     # Android version
   $ADB shell getprop ro.product.model             # model
   ```

   Parse the resolution and density (dpi) — `inspect_ui.py` needs dpi.

4. **Resolve target package.** If `PACKAGE` is empty, read the focused
   app:

   ```bash
   $ADB shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -1
   ```

   Extract the `package/activity` token. Confirm the resolved app with
   the user if it was auto-detected and ambiguous.

5. **Create dirs.**

   ```bash
   mkdir -p "$OUTPUT_DIR/assets"
   ```

---

### Phase 1 — Auto-explore & capture (guardrailed)

Walk the app breadth-first from the current screen, bounded by
`MAX_SCREENS` and `MAX_DEPTH`. Maintain in your working notes:

- a **visited set** keyed by `activity + structural-hash` (hash of the
  sorted resource-ids/classes in the dump) to detect loops,
- a **frontier** of `(screen, element)` taps still to try, with depth,
- a running screen counter `NN` (zero-padded: `screen-01`, …).

**Capture routine** (run for every new screen before exploring it):

```bash
NN=01   # increment per screen
$ADB exec-out screencap -p > "$OUTPUT_DIR/assets/screen-$NN.png"
# UI dump — pull method is the most reliable across OEMs; retry once.
$ADB shell uiautomator dump /sdcard/uidump.xml >/dev/null 2>&1 \
  && $ADB pull /sdcard/uidump.xml "$OUTPUT_DIR/assets/screen-$NN.xml" >/dev/null
# focused activity for provenance
$ADB shell dumpsys window | grep -E 'mCurrentFocus' | head -1
```

If a dump fails (some screens block it), wait ~1s and retry; if it still
fails, keep the screenshot and note "no UI dump" for that screen — the
visual reviewer can still work from the image.

Extract candidate elements with the helper:

```bash
python3 "$SKILL_DIR/templates/inspect_ui.py" \
  "$OUTPUT_DIR/assets/screen-$NN.xml" \
  --density "$DPI" --package "$PACKAGE" --min-dp "$MIN_DP" \
  --danger-extra "$DANGER_EXTRA"
```

This JSON gives you, per element: `center` tap coords, `width_dp`/
`height_dp`, `interactive`, `is_text_input`, `in_package`, and `flags`
(`too_small`, `missing_desc`, `redundant_desc`, `danger`, `text_input`).

**Choosing the next action** — from this screen's interactive,
`in_package` elements not yet visited, pick one and:

- **`danger` flag present** → **AskUserQuestion**: show the element's
  text/label and ask whether to tap it. Default to **skip** and record
  it in `meta.notes` as `not explored (potentially destructive): "<label>"`.
  Only tap on explicit approval.
- **`text_input`** → skip by default; record `skipped text field: "<label>"`.
  Only fill (`$ADB shell input text "<safe value>"`) if the user approves a
  specific value.
- **otherwise** → tap the center:

  ```bash
  $ADB shell input tap "$CX" "$CY"
  sleep 0.8
  ```

**After every tap**, verify you're still in the app:

```bash
$ADB shell dumpsys window | grep -E 'mCurrentFocus' | head -1
```

If the focused package is no longer `$PACKAGE` (a tap opened the
browser, dialer, share sheet, another app), go back and mark the
element `leaves app`:

```bash
$ADB shell input keyevent KEYCODE_BACK
```

When a screen's branches are exhausted, backtrack with
`KEYCODE_BACK` and continue the frontier. Stop when the frontier is
empty or a cap is hit.

**Never silently truncate.** If you stop because `MAX_SCREENS` or
`MAX_DEPTH` was reached, or because too many danger elements were
skipped, append an explicit line to `meta.notes` (e.g.
`coverage capped at MAX_SCREENS=15; N screens left unexplored`).

Keep an in-memory `screens` list as you go: `{id, image, xml,
activity, tap_from}` (`tap_from` = the label/screen you tapped to reach
it, or `entry` for the first).

---

### Phase 2 — Review (four dimensions)

Fan out **one Agent subagent per captured screen, in parallel** (issue
the Agent calls in a single message). Give each subagent:

- the absolute path to `assets/screen-NN.png` (instruct it to **Read the
  PNG** so it actually views the UI),
- the element JSON from `inspect_ui.py` for that screen (paste it in),
- device metadata (resolution, dpi),
- the rubric below.

Each subagent returns a JSON array of findings; merge them all.

**Rubric — emit a finding object per issue:**

```json
{
  "screen": "screen-01",
  "dimension": "accessibility | visual | ux | content",
  "severity": "critical | high | medium | low | info",
  "title": "short imperative summary",
  "description": "what's wrong and why it matters",
  "recommendation": "concrete fix",
  "bounds": [left, top, right, bottom]
}
```

`bounds` is optional but **strongly preferred** when the issue maps to a
specific element — copy it from that element's `bounds` so the report
can draw an overlay box.

Dimension guidance:

- **accessibility** — seed from the helper flags: `too_small` (touch
  target `< MIN_DP`), `missing_desc` (icon/control a screen reader can't
  announce), `redundant_desc`. Add judgment: contrast that looks low in
  the screenshot, unlabeled inputs, focus-order concerns.
- **visual** — alignment, spacing/rhythm, inconsistent components,
  color/contrast, typography scale, visual hierarchy, density, truncation.
- **ux** — affordance clarity, navigation depth, consistency across the
  captured screens, missing empty/error/loading states, destination of
  primary actions, back-stack behavior.
- **content** — microcopy clarity and tone, label accuracy, jargon,
  truncated/overflowing strings, placeholder/lorem text, untranslated
  strings.

Calibrate severity: `critical` = blocks a user or loses data/money;
`high` = clearly wrong, hurts most users; `medium` = noticeable polish
gap; `low`/`info` = minor or subjective.

Write the merged result to `"$OUTPUT_DIR/findings.json"` as
`{"findings": [ ... ]}`.

---

### Phase 3 — Build report

Write `meta.json` from what you gathered:

```json
{
  "app": "<app name or package>",
  "package": "<package>",
  "device": "<model>",
  "android": "<version>",
  "resolution": "1080x2400",
  "density": 420,
  "date": "<today>",
  "screens": [ {"id":"screen-01","image":"screen-01.png","activity":"...","tap_from":"entry"}, ... ],
  "notes": [ "coverage / skipped-danger lines from Phase 1", ... ]
}
```

Then build the HTML (and a PDF in the same step):

```bash
python3 "$SKILL_DIR/templates/build_report.py" \
  "$OUTPUT_DIR/findings.json" \
  --meta "$OUTPUT_DIR/meta.json" \
  --assets "$OUTPUT_DIR/assets" \
  --css "$SKILL_DIR/templates/report.css" \
  --out "$OUTPUT_DIR/report.html" \
  --pdf "$OUTPUT_DIR/report.pdf"      # optional; omit for HTML only
```

This inlines the CSS, draws bounding boxes for findings that carry
`bounds` (writing `assets/screen-NN.annotated.png`), and references the
PNGs by relative path so `report.html` + `assets/` move together.

The stylesheet is **print/PDF-first**: a light, paginated document
layout (`@page` A4, screenshots floated beside their findings,
`break-inside` guards so no finding splits across a page boundary, and
exact colour printing). So the HTML converts to a clean PDF with no
tweaking.

`--pdf` renders that PDF via **headless Chromium** (auto-detected:
`chromium` / `chromium-browser` / `google-chrome` / `chrome`). If no
Chromium is found the script still writes the HTML and tells the user to
use the browser's **Print → Save as PDF** (the layout is already
print-ready). Do not reach for heavyweight converters (wkhtmltopdf,
pandoc/TeXLive, md2pdf) — the headless-Chromium path is the supported
one.

If Pillow is missing the script still produces the report (screenshots
without overlays) and adds a note; mention installing `pillow` if the
user wants annotated images.

---

### Phase 4 — Summary

Print to the user:

- absolute path to `report.html` (and `report.pdf` if generated) and the
  output dir,
- screens captured and total findings,
- counts by **severity** and by **dimension**,
- the top 3–5 issues (highest severity first),
- any coverage caps hit or danger elements skipped (from `meta.notes`),
- an open hint: `xdg-open "<output_dir>/report.pdf"` (or the `.html`).
