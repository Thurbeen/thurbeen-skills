---
name: drawio
description: Generate a DrawIO Azure cloud-architecture diagram from a natural-language description. Always writes a `.drawio.png` — a PNG with the editable mxfile XML embedded in a PNG text chunk, so the same file renders inline in markdown and opens as an editable diagram in app.diagrams.net or drawio-desktop. AWS and GCP are not supported in v1.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep
---

## DrawIO

Turn a natural-language Azure architecture description into a
`.drawio.png` that you can drop straight into a README. The PNG
carries the editable mxfile XML inside a PNG text chunk
(drawio-desktop writes `zTXt`/`mxGraphModel`; app.diagrams.net writes
`tEXt`/`mxfile` — both forms are accepted on re-open), so drag-drop
into app.diagrams.net or the drawio VS Code extension re-opens it as
a fully editable diagram with real Azure icons.

**Input:** `$ARGUMENTS` is a free-form description. An optional
trailing `→ <path>.drawio.png` (or `-> <path>.drawio.png`) overrides
the output path. Defaults to `./diagram.drawio.png`.

**Output:** a single `.drawio.png` file at the resolved path.

**Provider in v1:** Azure (image-based, `img/lib/azure2/...`). AWS
and GCP are out of scope and refused in Phase 0.

### Inputs you should expect

- "A web app behind a load balancer, talking to a SQL database, with
  monitoring" → Azure is assumed; map services to the closest Azure
  equivalents.
- "Azure: Front Door → App Service → Cosmos DB → Azure Monitor."
- A path override: `... → docs/architecture.drawio.png`.

---

### Phase 0 — Pre-flight & dep check

```bash
command -v drawio   >/dev/null || { echo "drawio CLI not on PATH"; MISSING=1; }
command -v xmllint  >/dev/null || { echo "xmllint not on PATH";    MISSING=1; }
if [[ "$(uname -s)" == "Linux" ]]; then
  command -v xvfb-run >/dev/null || { echo "xvfb-run not on PATH"; MISSING=1; }
fi
[[ -n "${MISSING:-}" ]] && {
  cat <<'EOF'
Install the missing dependencies:
  - drawio-desktop: https://github.com/jgraph/drawio-desktop/releases
    Debian/Ubuntu: download drawio-amd64-*.deb, then `sudo dpkg -i`.
  - xvfb (Linux only):   sudo apt-get install -y xvfb
  - xmllint:             sudo apt-get install -y libxml2-utils
EOF
  exit 1
}
```

Resolve the output path from `$ARGUMENTS`:

- If `$ARGUMENTS` contains `→` or `->`, split on the first
  occurrence; right-hand side is the output path.
- Otherwise default to `./diagram.drawio.png`.
- Refuse to proceed unless the resolved path ends in `.drawio.png`.

**Refuse AWS-only or GCP-only requests** (substring match on
`aws`, `ec2`, `s3`, `lambda`, `rds`, `route 53`, `cloudfront`,
`alb`, `nlb`, `vpc`, `iam`, `gcp`, `google cloud`,
`compute engine`, `bigquery`, `pub/sub`) with:

> "AWS and GCP are not supported in v1 — this skill emits Azure
> stencils only. Use Azure resources, or render non-Azure
> components as plain labeled rectangles by passing
> `--allow-fallback` (out of scope for v1)."

If the description mixes Azure with isolated AWS/GCP references
(e.g. "Azure App Service that calls an external S3 bucket"), proceed
with Azure and treat the external service as out-of-scope text only —
do not try to render an AWS icon.

---

### Phase 1 — Interpret the request

Read `skills/drawio/templates/stencils.yaml` (use `Read` on the
absolute path; the skill is symlinked from `~/.claude/skills/drawio/`
to its source — resolve the symlink with `readlink -f` if you need
the real path).

Phase 1 assumes Azure. From `$ARGUMENTS`:

1. **Map services to catalog keys.** For each service named in the
   description, find its key in the catalog (e.g. "Function App" →
   `azure.function_apps`, "Front Door" → `azure.front_doors`). If a
   service isn't in the catalog, ask the user whether to skip it or
   pick a near match; never silently invent a new stencil id.
2. **Enumerate edges.** Walk the description and list
   `(source_key, target_key, label?, kind)` tuples. `kind` is
   `data` (default), `control` (telemetry, auth, DNS, audit), or
   `peering` (bidirectional links: VNet peering, two-way
   replication, mTLS service-mesh).
3. **Identify containers.** Scan the description for **Azure scope
   words** that imply a zone: `vnet`, `virtual network`, `subnet`,
   `landing zone`, `hub`, `spoke`, `resource group`, `subscription`,
   `region`, `management group`, `tenant`. Every container becomes
   a zone in Phase 2.
4. **Assign each non-container node a tier.** Tiers drive row
   placement *inside* a zone:
   `ingress` (DNS, CDN, WAF, LB, API gateway) →
   `compute` (VMs, containers, functions, app services) →
   `data` (DBs, caches, queues, storage) →
   `observability` (monitor, logs, traces) →
   `identity` (Entra, managed identities) →
   `security` (Key Vault, firewall, Defender).

Hold this model in mind for Phase 1.5–1.9. Don't ask the user to
review it unless you had to make a genuinely ambiguous choice.

---

### Phase 1.5 — Design check (interactive)

The skill used to silently make several design-direction choices in
Phase 1 (grouping, orientation, what accent icons to add, edge
density). Past runs showed those silent choices cost iterations in
Phase 5.5 — by the time the visual review fires, the wrong
structural choice is already baked in. Phase 1.5 surfaces the
decisions to the user *before* layout commits.

**Trigger.** Run Phase 1.5 only when:
- `n_zones >= 2` (multi-zone topology), OR
- `n_services >= 6` (moderately complex flat diagram).

For smaller diagrams (single zone, ≤5 services), **skip Phase 1.5
entirely**. The defaults below apply silently:
- `diagram_type = infrastructure`
- `grouping = follow Phase 1 container scan`
- `orientation = side-by-side if multi-zone else flat`
- `accents = none` (no Internet, no Resource Group, no wireframe)
- `edge_density = show all` (auto-bundling in Phase 1.9 still runs)

**Step B — Ask via `AskUserQuestion`.** `AskUserQuestion` is
capped at 4 questions per call, so send the five questions below
across **two batched calls** (e.g. Q1+Q2+Q3+Q4 first, then Q5).
For each question, mark the option that matches the skill's Phase
1 inference as `(Recommended)`. Use multiSelect only for the
Accents question.

**Question 1 — Diagram type.** What kind of diagram?
- Infrastructure (Azure resources + network)
- Application architecture (services, APIs, data flows)
- Data flow (sources → transforms → sinks, telemetry pipelines)
- Network topology (VNets, subnets, peering, routing)

(The diagram type narrows icon emphasis and edge semantics. For
*application*, deemphasize network appliances; for *data flow*,
use directional arrows everywhere and minimize containers; for
*network*, foreground VNets / subnets / peering edges.)

**Question 2 — Grouping.** How should resources be grouped?
- The grouping I inferred (list the zones from Phase 1 in the
  option label, e.g. "AI LZ / Hub / AKS LZ")
- By tier (ingress / compute / data / observability)
- By environment (dev / staging / prod)
- Flat (no zones, just icons on the canvas)

If the user picks "By tier" or "By environment", rebuild the zone
list before Phase 1.7. If "Flat", drop all zones entirely.

**Question 3 — Orientation.** Layout direction?
- Side-by-side (zones in columns)
- Top-to-bottom (zones stacked in rows)
- Auto (Claude picks per zone count: side-by-side for ≤3 zones,
  stacked above)

**Question 4 — Optional accents** (multiSelect: true, default = no
boxes checked). Add any of these decorative elements?
- `Internet icon` — external entry point at the left edge, with
  dashed `DNS Lookup` and `Authentication` edges to public services
- `Resource Group icon` — small Azure resource group glyph at the
  bottom-left
- `On-prem / hybrid entry point` — labeled rectangle representing
  on-prem datacenter, connected to a VPN Gateway or ExpressRoute
- `Region / subscription wireframe` — outer dashed boundary
  enclosing everything

**Without explicit opt-in, none of these are emitted.** This
reverses the previous auto-add-when-N-S-traffic-mentioned
heuristic, which surprised users by inserting unwanted icons.

**Question 5 — Edge density.** Which relationships to show?
- All inferred edges (data plane + every control-plane edge —
  auto-bundling in Phase 1.9 still applies)
- Data plane only (drop dashed control-plane edges)
- Bundle control plane aggressively (one labeled dashed edge per
  spoke, value "Logs / DNS / AuthN/Z" — for hub-and-spoke topologies
  where every spoke fans 4+ control-plane edges into the hub)

**Step C — Apply answers** to the in-memory model from Phase 1:
- *Diagram type*: rebalance which services count as "important"
  (keep all, but adjust edge emphasis).
- *Grouping*: rebuild zones if the user picked a different scheme.
- *Orientation*: set a flag Phase 2 reads when placing zones.
- *Accents*: for each checked accent, add a top-level item to the
  scene graph (`accents[]`):
  - Internet → top-level icon at the leftmost column, plus dashed
    edges to whatever the user's services labeled "public" /
    "ingress" / "DNS" / "auth".
  - Resource Group → top-level 36×36 icon at the bottom-left.
  - On-prem → top-level labeled rectangle, connect via VPN GW.
  - Wireframe → outer Layer A rectangle (variant: `fillColor=none`).
- *Edge density*: if "Data plane only", drop every `kind=control`
  edge. If "Bundle aggressively", set a flag for Phase 1.9 to also
  bundle pairs (`src_zone`, `dst_node`) with 2 edges (not just 3+).

---

### Phase 1.6 — Design preview (interactive, bounded)

Before Phase 1.7 commits the scene graph, print a compact text
outline so the user can correct structural mistakes cheaply.
Skip this phase if Phase 1.5 was skipped (small diagrams).

**Print this exact structure** (using box-drawing chars):

```
Proposed design:

Diagram type: <Diagram type from Q1>
Orientation:  <Orientation from Q3>
Grouping:
  ┌─ Zone A: <zone label>
  │    <comma-separated service labels>
  ├─ Zone B: <zone label>
  │    <comma-separated service labels>
  └─ Zone C: <zone label>
       <comma-separated service labels>

Accents: <comma-separated, or "(none)">

Edges: <N> total — <breakdown>
        e.g. "9 intra-zone, 2 VNet peering, 2 bundled control plane"
```

Then **ask via `AskUserQuestion`** (single question, four options):

- **OK to render?**
  - Yes, render → proceed to Phase 1.7.
  - Move a service between zones → user names which service and
    where (use "Other"); apply change, reprint preview, re-ask.
  - Add or remove an edge → user describes via "Other"; same loop.
  - Change grouping / orientation / accents → reopen Phase 1.5
    questions for the user.

**Bound the loop at 3 iterations.** Track `PREVIEW_ITERS_LEFT = 3`.
If the user keeps requesting changes after 3 cycles, ship the
best-effort design and note unresolved requests in Phase 6.

---

### Phase 1.7 — Emit the scene graph

This is the source of truth for everything downstream. **No
coordinates yet** — just structure. Phases 2–3 derive geometry
from this; Phase 5.5 retries edit this object, not the XML.

Build the following JSON object in memory (no file write):

```json
{
  "diagram_type": "infrastructure|application|data_flow|network",
  "orientation": "side_by_side|stacked|auto",
  "zones": [
    { "id": "Z1", "label": "Hub VNet", "parent_zone": null,
      "fill": "soft_gray" }
  ],
  "nodes": [
    { "id": "N1", "key": "azure.front_doors", "label": "Front Door",
      "tier": "ingress", "zone": "Z1", "group": null }
  ],
  "groups": [
    { "id": "G1", "members": ["N3","N4"], "zone": "Z1", "label": null }
  ],
  "edges": [
    { "id": "E1", "src": "N1", "dst": "N2", "label": "HTTPS",
      "kind": "data", "bidirectional": false }
  ],
  "accents": ["internet", "resource_group", "wireframe", "onprem"]
}
```

Field rules:
- `zones[].fill` is one of `soft_gray` (default, `#E6E6E6`),
  `wireframe` (`none` fill + `#7F7F7F` stroke), `inner_gray`
  (`#F0F0F0`, for nested zones).
- `zones[].parent_zone` enables nesting. Max depth 4 (CAF rule:
  Tenant → MG → Sub → RG → VNet → Subnet collapses if the user
  doesn't ask for all six levels — keep ≤4 visible levels).
- `nodes[].key` MUST be a key present in `stencils.yaml`, written
  as `<provider>.<service>` (e.g. `azure.front_doors`,
  `azure.storage_blob`). The provider prefix is stripped before the
  yq lookup against `azure.services` or `azure.legacy_shapes`. Use
  legacy shapes for storage primitives (blob/queue/table).
- `nodes[].tier` is one of `ingress`, `compute`, `data`,
  `observability`, `identity`, `security`. Phase 2 uses it for
  ordering inside a zone.
- `nodes[].zone` may be null for accent icons (Internet etc.).
- `groups[]` is OPTIONAL — only used when 2–3 icons must drag
  together as one block (App Service Plan + Web App; AKS + pod).
- `edges[].kind`: `data` (solid blue), `control` (dashed black),
  `peering` (bidirectional blue with arrows on both ends).
- `edges[].bidirectional` forces both-arrow rendering regardless of
  `kind`. Set true for VNet peering, two-way replication, mTLS.
- `accents[]` lists which optional decorations are enabled (from
  Phase 1.5 Q4).

If `$ARGUMENTS` contains the substring `debug`, print the assembled
JSON to stdout before proceeding to Phase 1.8 (useful during skill
development).

---

### Phase 1.8 — Validate the scene graph

Run these self-checks against the JSON from Phase 1.7. If any check
fails, fix the JSON and re-run validation. Do NOT proceed to Phase
1.9 with a broken scene graph.

1. Every `nodes[].key` exists in `stencils.yaml.azure.services` or
   `stencils.yaml.azure.legacy_shapes`.
2. Every `nodes[].zone` is either null or matches a `zones[].id`.
3. Every `edges[].src` and `edges[].dst` references an existing
   `nodes[].id`.
4. Every `groups[].members[]` references an existing `nodes[].id`,
   and all members share the same `zone`.
5. `zones[].parent_zone` graph is acyclic; depth ≤ 4.
6. Node ids, zone ids, group ids, edge ids are unique.
7. `tier` values are within the allowed enum.

A trivial bash check for #1 (run once `$TMP_GRAPH` holds the JSON):

```bash
yq -r '.. | select(has("key")) | .key' "$TMP_GRAPH" 2>/dev/null \
  | sed 's/^azure\.//' \
  | while read -r k; do
      yq -e ".azure.services.$k // .azure.legacy_shapes.$k" \
        "$SKILL_DIR/templates/stencils.yaml" >/dev/null \
        || { echo "fail: unknown key azure.$k"; exit 1; }
    done
```

(Most validation is done by Claude reading the JSON; the bash check
above is illustrative — the real authority is Claude's self-check.)

---

### Phase 1.9 — Auto-bundle control-plane edges

Before layout, collapse runs of redundant dashed edges. Group
`edges[]` where `kind == "control"` by `(src_zone, dst)`:

- If 3+ edges share that pair → collapse to ONE edge whose label is
  the original labels joined by ` / ` (e.g. `Logs / Metrics / Audit`).
  The single src node for the bundled edge is the topmost (smallest
  tier index) icon in the source zone.
- If Phase 1.5 Q5 = "Bundle aggressively" → lower the threshold to 2.
- If Phase 1.5 Q5 = "Data plane only" → drop all control edges
  entirely; no bundling needed.

Record bundles in the scene graph by replacing the original edges
with the merged edge. Remember the bundle stats — Phase 6 reports
"Bundled N edges from zone X to node Y."

If a bundled label exceeds 24 chars, split into two bundled edges
(e.g. `Logs / Metrics` + `AuthN-Z / DNS`).

---

### Phase 2 — Lay out cells

The previous version of this skill told Claude to hand-route edges
with `exitX/exitY/entryX/entryY` and `<Array as="points">` waypoints.
**Do not do that.** drawio's ELK pass routes edges automatically and
will fight any manual routing you add — that's what caused the
overlap problems on past runs. Author *logical structure*; let ELK
handle pixels.

This phase derives coordinates from the validated scene graph using
deterministic packing + alignment rules.

**Constants:**

```
ICON_GAP   = 40    # between icons within a zone
LAYER_GAP  = 80    # between tier rows
ZONE_PAD   = 20    # inside zone (around icons)
ZONE_GAP   = 60    # between zones
TITLE_ROOM = 24    # vertical room for floated zone title
```

Icon dimensions come from `stencils.yaml.azure.default_size`
(64×64). Labels render below the icon via the provider's
`style_template` (already encoded — don't override).
Each cell gets a unique numeric `id` starting at `10` (reserve
`0` and `1` for the sentinels).

**Step A — Build zones as zone rectangles, not swimlanes.**

Earlier versions of this skill used `shape=swimlane;container=1;`.
We don't anymore — the saturated borders and title bars make
diagrams look like UML, not like the Azure whitepaper style
captured in `example.drawio.png`. The new pattern is three-layered.

**Layer A — Zone rectangle (decorative, no parent role).**

For every zone in `scene.zones`, emit a plain rectangle as the
visual backdrop. Style depends on `zones[].fill`:

| fill         | style |
|--------------|-------|
| `soft_gray`  | `rounded=0;whiteSpace=wrap;html=1;dashed=1;fillColor=#E6E6E6;strokeColor=none;labelBackgroundColor=none;` |
| `wireframe`  | `rounded=0;whiteSpace=wrap;html=1;dashed=1;fillColor=none;strokeColor=#7F7F7F;labelBackgroundColor=none;` |
| `inner_gray` | `rounded=0;whiteSpace=wrap;html=1;dashed=1;fillColor=#F0F0F0;strokeColor=none;labelBackgroundColor=none;` |

The zone rectangle's `value=` is empty (`value=""`) — its title
is rendered SEPARATELY as a free-floating text cell positioned
above (or below) the rectangle. This matches the example, where
"App Service Plan" floats above its gray block rather than living
in a title bar.

Free-floating title text cell style:
```
text;html=1;strokeColor=none;fillColor=none;align=center;verticalAlign=middle;whiteSpace=wrap;rounded=0;fontSize=14;fontStyle=1;
```

**Layer B — Optional `group;` cluster (real parent-child).**
Use ONLY when `scene.groups[]` has an entry — i.e. two or three
icons must drag together (e.g. App Service Plan rectangle + Web
App icon inside it; AKS Cluster + representative pod). Otherwise
omit.

```
group;labelBackgroundColor=none;strokeColor=none;
```

Children of a `group;` cell use coordinates *relative to* the
group, and inherit drag/move behavior.

**Layer C — Icon cell.** Azure SVG-based style. The icon's
`parent` is:
- `"<group_id>"` if it's inside a Layer B `group;` cluster
  (coords relative to the group), OR
- `"1"` for everything else (absolute coords).

**Icons are NOT children of Layer A zone rectangles.** Zones are
decorative backdrops; icons sit on top in absolute coordinates.
The visual "containment" works because we render the zone *first*
(behind), the icons *after* (in front), and we place the icons
geometrically within the zone's bounds.

**Z-order rule.** Drawio renders cells in document order, with
later cells on top of earlier ones. Emit in this order:
1. Outer wireframe boundary (if any)
2. Layer A zone rectangles (gray backdrops)
3. Layer B `group;` cells
4. Free-floating title text cells for zones
5. Layer C icon cells
6. Edges
7. Legend (if mixed-edge diagrams — see Phase 3.5b)

**Step B — Pack icons within each zone.**

For each `zone` in `scene.zones`:

1. Filter `scene.nodes` to those with `node.zone == zone.id`.
2. Sort by tier order: `ingress`, `compute`, `data`,
   `observability`, `identity`, `security`.
3. Choose column count `cols`:
   - `n ≤ 2` → 1 row of `n`
   - `3 ≤ n ≤ 4` → 2 columns × 2 rows
   - `5 ≤ n ≤ 6` → 3 columns × 2 rows
   - `n ≥ 7` → 3 columns × `ceil(n/3)` rows
4. Pack tier-first: each row should hold at most one tier when
   possible. If a tier has more icons than `cols`, wrap the
   overflow into the next row (still that tier first), then start
   the next tier on the row after that.
5. Compute zone geometry:
   ```
   icon_w = icon_h = 64
   rows   = ceil(n / cols)
   zone.width  = ZONE_PAD*2 + cols * icon_w + (cols-1) * ICON_GAP
   zone.height = ZONE_PAD*2 + TITLE_ROOM + rows * icon_h + (rows-1) * LAYER_GAP
   ```
6. Icon positions inside the zone (top-left origin = zone top-left):
   ```
   icon.col_in_zone  = (index % cols)
   icon.row_in_zone  = (index // cols)
   icon.x = zone.x + ZONE_PAD + col_in_zone * (icon_w + ICON_GAP)
   icon.y = zone.y + ZONE_PAD + TITLE_ROOM + row_in_zone * (icon_h + LAYER_GAP)
   ```

**Step C — Align zones.**

- **Side-by-side orientation**: all zones share `y = 80`. Compute
  `max_zone_height = max(z.height for z in zones)`. Set every
  zone's height to `max_zone_height`. Icons within shorter zones
  remain at their packed positions (top-aligned inside the zone) —
  this preserves tier ordering. Place zones left-to-right with
  `ZONE_GAP` between them, starting at `x = 40`.
- **Stacked orientation**: all zones share `x = 40`. Stack
  vertically with `ZONE_GAP` between them.
- **Auto orientation**: side-by-side if `zone_count ≤ 3` else
  stacked.
- **Nested zones (`parent_zone != null`)**: place nested zone with
  `ZONE_PAD` inside the parent's content area. Inner zone's
  `fill = inner_gray`. Nested zones contribute to the parent's
  computed `width`/`height` instead of using the packing rule
  above directly.

**Step D — Place accent icons.**

For each entry in `scene.accents`:
- `internet` → top-level icon at `x = 40, y = (page_center_y - 32)`.
  Shift all zones right by 120 px to make room. Emit dashed edges
  from Internet to whichever icons have `tier == "ingress"` AND
  zone is null OR zone is the leftmost zone.
- `resource_group` → 36×36 icon at the bottom-left
  (`x = 40, y = pageHeight - 80`).
- `onprem` → labeled rectangle 160×60 at top-left, connected to
  any `vpn_gateway` or `expressroute` node via a solid edge.
- `wireframe` → outer Layer A rectangle with `fill = wireframe`
  wrapping all zones plus accents.

**Step E — Page bounds.**

```
pageWidth  = max(zone.x + zone.width)  + 80
pageHeight = max(zone.y + zone.height) + 80
```

If the legend will be emitted (see Phase 3), add 80 px to
`pageHeight` to make room for it in the bottom-right.

---

### Phase 3 — Generate mxfile XML

Read `skills/drawio/templates/mxfile.xml.tmpl`. For each Azure icon
node, build the style string from
`stencils.yaml.azure.style_template` by substituting `{path}` with
`img/lib/azure2/<category>/<File>.svg` from the catalog entry. For
storage primitives, use the catalog's `legacy_shapes` style verbatim
(`storage_blob`, `storage_queue`, `storage_table`).

**Emit a zone rectangle (Layer A)** as:

```xml
<mxCell id="<C>" value="" style="<zone_style>" vertex="1" parent="1">
  <mxGeometry x="<X>" y="<Y>" width="<W>" height="<H>" as="geometry"></mxGeometry>
</mxCell>
```

Zone rectangles always have `parent="1"` and `value=""`. Their
title comes from a separate text cell (next item).

**Emit a zone title (free-floating text)** as:

```xml
<mxCell id="<T>" value="<title>" style="text;html=1;strokeColor=none;fillColor=none;align=center;verticalAlign=middle;whiteSpace=wrap;rounded=0;fontSize=14;fontStyle=1;" vertex="1" parent="1">
  <mxGeometry x="<X>" y="<Y-25>" width="<zone_width>" height="20" as="geometry"></mxGeometry>
</mxCell>
```

Position the title row 25 px above the zone's top edge (`Y-25`),
centered on the zone's width.

**Emit a `group;` cluster (Layer B, optional)** as:

```xml
<mxCell id="<G>" value="" style="group;labelBackgroundColor=none;strokeColor=none;" vertex="1" connectable="0" parent="1">
  <mxGeometry x="<X>" y="<Y>" width="<W>" height="<H>" as="geometry"></mxGeometry>
</mxCell>
```

The group's geometry must exactly enclose its children. Children
declare `parent="<G>"` and use coords relative to the group.

**Emit an icon (Layer C)** as:

```xml
<mxCell id="<N>" value="<label>" style="<style>" vertex="1" parent="<P>">
  <mxGeometry x="<X>" y="<Y>" width="64" height="64" as="geometry"></mxGeometry>
</mxCell>
```

`<P>` is `"1"` for free-floating icons OR a group id for icons
inside a Layer B cluster.

**Edge style strings.** Define these four named styles once and
reuse them for every edge:

```
EDGE_BASE     = edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;jettySize=auto;orthogonalLoop=1;jumpStyle=arc;jumpSize=8;labelBackgroundColor=none;
EDGE_DATA     = EDGE_BASE + fillColor=#dae8fc;strokeColor=#6c8ebf;
EDGE_CONTROL  = EDGE_BASE + dashed=1;
EDGE_PEERING  = EDGE_BASE + startArrow=classic;endArrow=classic;strokeColor=#6c8ebf;fillColor=#dae8fc;
```

`jumpStyle=arc;jumpSize=8` makes drawio render small arcs at
edge crossings — cleaner reads at zero cost.

**Pick the style per edge** based on the scene graph:
- `edge.bidirectional == true` → `EDGE_PEERING` (overrides `kind`).
- `edge.kind == "data"` → `EDGE_DATA`.
- `edge.kind == "control"` → `EDGE_CONTROL`.
- `edge.kind == "peering"` → `EDGE_PEERING`.

**Emit each edge.** ALL edges have `parent="1"` — this lets ELK
route them across zone boundaries cleanly.

```xml
<mxCell id="<N>" value="<label>" style="<edge_style>" edge="1" parent="1" source="<src>" target="<dst>">
  <mxGeometry relative="1" as="geometry"></mxGeometry>
</mxCell>
```

Labels go **inline on the edge** via `value="<label>"`. If a
label overlaps a line on the rendered PNG, the Phase 5.5 visual
review will catch it and the fix is structural (move source/target
or shorten the label), not `labelBackgroundColor=#FFFFFF`.

**Do NOT add any of these to edges:**
- `exitX`, `exitY`, `exitDx`, `exitDy`, `entryX`, `entryY`,
  `entryDx`, `entryDy`
- `<Array as="points">` waypoint blocks
- `jettySize` overrides (the default `auto` is correct)

**3.5b — Auto-emit a legend** when the scene graph has both
`kind=data` and `kind=control` edges (after Phase 1.9 bundling).
Emit FOUR cells in the bottom-right of the page:

```
legend_x = pageWidth - 200
legend_y = pageHeight - 80
```

1. **Title** — text cell at `(legend_x, legend_y)`:
   ```xml
   <mxCell id="<L1>" value="Legend" style="text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;whiteSpace=wrap;rounded=0;fontSize=12;fontStyle=1;" vertex="1" parent="1">
     <mxGeometry x="<legend_x>" y="<legend_y>" width="60" height="16" as="geometry"></mxGeometry>
   </mxCell>
   ```
2. **Data-plane swatch** — two invisible 1×1 anchor cells + one
   edge using `EDGE_DATA` style, label `"Data plane"`. Position
   anchors at `(legend_x, legend_y + 26)` and
   `(legend_x + 40, legend_y + 26)`.
   Anchor style: `shape=mxgraph.shapes.transparent;strokeColor=none;fillColor=none;`
3. **Control-plane swatch** — same pattern with `EDGE_CONTROL`,
   label `"Control plane"`, at `legend_y + 50`.

If `EDGE_PEERING` is also in use, add a third swatch row at
`legend_y + 74` with label `"Peering"` and extend `pageHeight`
accordingly.

**XML hygiene rules:**

1. **Never emit XML comments** (`<!-- ... -->`). Drawio strips them
   and can corrupt the output.
2. **Expanded geometry, not self-closing.** Edge geometries must be
   `<mxGeometry relative="1" as="geometry"></mxGeometry>` (open + close
   tags).
3. **XML-escape every `value=` and label.** Map
   `& < > " '` → `&amp; &lt; &gt; &quot; &apos;`. Newlines inside
   labels become `&lt;br&gt;` or `&#xa;`.
4. **Non-rectangular shapes need matching `perimeter`** (rare for
   cloud icons but possible for decision/data-store shapes).
5. **Sentinels are mandatory.** `<mxCell id="0"/>` and
   `<mxCell id="1" parent="0"/>` must be the first two cells under
   `<root>`. The mxfile.xml.tmpl already includes them.
6. **No `shape=swimlane`.** Earlier versions used swimlanes; Phase
   4 rejects any occurrence.

Write the populated XML to a temp file:

```bash
TMP_XML="$(mktemp -t drawio-XXXX.xml)"
# (write the rendered XML to $TMP_XML via the Write tool)
```

---

### Phase 4 — Validate XML

```bash
xmllint --noout "$TMP_XML" || { echo "invalid XML"; cat "$TMP_XML"; exit 1; }

# No XML comments anywhere.
grep -q '<!--' "$TMP_XML" && { echo "fail: XML comments present"; exit 1; }

# No self-closed edge geometries.
grep -q '<mxGeometry relative="1" as="geometry"/>' "$TMP_XML" \
  && { echo "fail: edge geometries must be expanded, not self-closed"; exit 1; }

# No hand-routing attributes on edges (these fight ELK).
if grep -E '(exitX|exitY|entryX|entryY)=' "$TMP_XML" >/dev/null; then
  echo "fail: edges contain exitX/Y or entryX/Y — let ELK route"; exit 1
fi
if grep -q '<Array as="points">' "$TMP_XML"; then
  echo "fail: edges contain waypoint arrays — let ELK route"; exit 1
fi

# No swimlane containers (we use zone-rectangle + group; instead).
if grep -q 'shape=swimlane' "$TMP_XML"; then
  echo "fail: shape=swimlane found — use zone rectangles + group; cells"; exit 1
fi
```

Then check edge references: every `source=` and `target=` on an
`edge="1"` cell must match an existing cell id. Pull node ids with
`grep -oE 'mxCell id="[0-9]+"'`, pull edge endpoints with
`grep -oE '(source|target)="[0-9]+"'`, diff.

Then check parent references: every cell with `parent="<N>"` where
`<N>` is not `0` or `1` must reference an existing cell id
(typically a `group;` cell). For icons declared `parent="1"`
that sit visually inside a zone rectangle, verify the icon's
absolute `x`/`y` falls inside the zone's bounding box.

If validation fails, regenerate Phase 3 with the offending node
fixed; do not ship a broken file.

---

### Phase 5 — Render PNG with embedded XML

```bash
SKILL_DIR="$(dirname "$(readlink -f "$HOME/.claude/skills/drawio")")/drawio"
python3 "$SKILL_DIR/templates/render.py" "$TMP_XML" "$OUTPUT_PATH"
```

`render.py` shells out to:

```
xvfb-run -a drawio --no-sandbox -x -f png -e -o <out> <in>
```

(Linux; on macOS/Windows the `xvfb-run` prefix is dropped.) The
`-e` flag embeds the editable mxfile XML (URL-encoded + zlib-deflated)
in a PNG `zTXt` chunk under keyword `mxGraphModel`. The script also
injects an alternate `tEXt`/`mxfile` form for the VS Code drawio
extension. It verifies one of those chunks is present before
reporting success.

Clean up the temp XML on success: `rm -f "$TMP_XML"`.

---

### Phase 5.5 — Visual review (feedback loop)

A drawio render that passes Phase 4's XML validators can still be
*visually* broken: edges may cut through icons, labels may stack on
each other, a service may end up clipped, a zone may be misaligned.
Phase 5.5 catches those issues by reading the rendered PNG back and
re-rendering up to **2 more times** if any rubric check fails.

**The PNG is multimodal**: when you `Read` it via the Read tool, the
image is shown inline and you can judge it directly — no OCR, no
external tools.

#### Procedure

1. `Read` the `$OUTPUT_PATH` PNG.
2. Run the 6-check rubric below against the visible image AND against
   the Phase 1.7 scene graph.
3. If all 6 checks pass → continue to Phase 6.
4. If any check fails AND `RETRIES_LEFT > 0`:
   - Identify the *root cause* of each failure (see the
     "Common fixes" table below).
   - Apply the corresponding fix **to the scene graph** (Phase 1.7
     object), not directly to the XML. Then re-run Phases 1.8, 1.9,
     2, 3, 4, 5.
   - Decrement `RETRIES_LEFT` and loop back to step 1.
5. If checks fail and `RETRIES_LEFT == 0` → ship the latest render,
   but in Phase 6 explicitly list which rubric checks were still
   failing.

Cap: **2 retries, 3 total renders.** Track `RETRIES_LEFT` starting at 2.

#### Rubric

For each check, ANSWER YES or NO based on the rendered PNG:

1. **No edges crossing icons.** Look at every icon. Does any edge
   (solid or dashed) pass through the body of an icon (not just
   touch its boundary)? If yes → FAIL.
2. **No label overlap.** Do any two edge labels overlap each other?
   Does any edge label sit on top of an icon body or icon caption?
   If yes → FAIL.
3. **All services present and labeled.** Cross-check the scene
   graph's `nodes[]`. Is every node visibly rendered with a
   readable label? (Allow truncation only if the label is still
   readable.) If any service is missing or its label is clipped/
   illegible → FAIL.
4. **Containers clearly visible.** For every zone rectangle, is its
   floated title legible, and do its child icons visually sit
   inside its bounds? If a title is obscured by an edge, or
   children spill outside their container → FAIL.
5. **Edge density.** Count the visible edges. If the diagram has
   more than 25 edges, or any single zone has 3+ unbundled
   control-plane edges fanning to the same target → FAIL.
6. **Zone alignment.** Side-by-side orientation: do all zone top
   edges sit at the same `y` (within 5 px)? Stacked orientation:
   do all zone left edges share the same `x`? If no → FAIL.

#### Common fixes (map failure → adjustment)

| Failure | Adjustment for the next render |
|---|---|
| Edge crosses icon | Move source or target node to a less crowded position; or split the source zone (add a column). |
| Edge label sits on icon | Shorten the label to ≤14 chars in the scene graph, or shift the source/target. |
| Two labels overlap | Drop the less-important edge's label entirely (keep the edge). |
| Service missing | Phase 3 dropped it — re-emit; double-check the node's `zone` references a real zone. |
| Label clipped | Re-pack the zone with a wider column count (Phase 2 Step B). |
| Container title obscured | Add an extra row of TITLE_ROOM by increasing the zone's `y` by 16 px. |
| Children outside container | Bug in Phase 2 packing — re-run Step B for that zone. |
| Unequal zone heights (side-by-side) | Apply Step C `max_zone_height` rule; vertically center icons inside shorter zones if needed. |
| Legend missing despite mixed edges | Emit legend block (Phase 3.5b). |
| Bundled label too long | Split bundled edge into two (e.g. `Logs/Metrics` + `AuthN-Z/DNS`). |
| Tangle around shared target | Lower auto-bundle threshold from 3 to 2 for that `(src_zone, dst)` pair. |
| Zones misaligned | Recompute zone positions (Phase 2 Step C). |

**Allowed levers for retries**:
- Move nodes between zones, change `tier`, split or merge zones.
- Drop, add, or relabel edges; change `kind` or `bidirectional`.
- Adjust `accents[]`.
- Re-pack icons within a zone (rerun Phase 2 Step B with a different
  `cols` choice).

**Do NOT respond to a failure by reintroducing hand-routing
(exit/entry anchors, waypoint arrays).** Those are still banned —
Phase 4 will reject the XML.

#### Bash plumbing

```bash
RETRIES_LEFT=2
while true; do
  # Phases 3-5 already ran; the PNG is at $OUTPUT_PATH.
  # Claude: Read "$OUTPUT_PATH" → judge rubric → decide PASS or list FAILS.
  # If PASS, break.
  # If FAIL and RETRIES_LEFT > 0:
  #   - apply fixes to the SCENE GRAPH (Phase 1.7 object),
  #   - re-run Phases 1.8, 1.9, 2, 3, 4, 5 (overwriting $TMP_XML and $OUTPUT_PATH).
  #   - RETRIES_LEFT=$((RETRIES_LEFT - 1))
  # If FAIL and RETRIES_LEFT == 0: break (ship best-effort).
  break  # placeholder — actual loop is driven by Claude's judgment
done
```

The loop is **driven by Claude reading the image**, not by a script.
The bash above is just a sketch — the real control flow is "Claude
reads PNG, decides, may regenerate."

---

### Phase 6 — Report

Print:

- Output path (absolute).
- File size and dimensions (`file "$OUTPUT_PATH"`).
- Number of nodes and edges (after bundling).
- The list of services included, grouped by tier.
- **Design-choice summary** — what Phase 1.5 settled on:
  - Diagram type, grouping, orientation, accents, edge density.
  - Or "Phase 1.5 skipped — defaults used" if the trigger
    thresholds weren't met.
  - Number of Phase 1.6 preview iterations and any unresolved
    change requests when the cap was hit.
- **Bundling stats** — for each bundle applied in Phase 1.9, print
  `Bundled N edges from zone X to node Y as "<merged label>"`.
- **Visual-review history:**
  - Number of render iterations (1, 2, or 3).
  - For each iteration, the rubric verdict and — if it failed —
    which checks failed and what adjustment was applied for the
    next attempt.
  - If the final render still has failing checks (cap exhausted),
    list them explicitly so the user knows what to fix manually.
- A ready-to-paste markdown embed line, relative to the user's CWD:
  `![architecture](<rel-path>)`.

Do **not** open the file, commit, or push. The user owns next steps.

---

## Appendix — Common topologies

Concrete recipes for the patterns that come up most often. Each
shows: (a) which cells are zone rectangles vs `group;` clusters
vs icons, (b) where the floating titles go, (c) which edges go
between which icons.

### Azure hub-and-spoke (Landing Zone pattern)

Three zone rectangles side-by-side, free-floating titles above each
zone. Internet, Resource Group, and the outer wireframe are
**optional accents** that only appear when the user opts in via
Phase 1.5 Question 4 — the base recipe has none of them.

**Base recipe (no opted-in accents):**

```
scene.zones = [
  { id: "ZA", label: "AI Foundry Landing Zone", fill: "soft_gray" },
  { id: "ZH", label: "Hub VNet",                fill: "soft_gray" },
  { id: "ZK", label: "AKS Landing Zone",        fill: "soft_gray" },
]
scene.orientation = "side_by_side"

scene.groups = [
  { id: "G-OBS", members: ["log_analytics_id", "monitor_id"], zone: "ZH" }
]  # so Log Analytics + Monitor drag together

scene.edges =
  • Each spoke compute icon → Hub Firewall : kind=data
  • One bundled dashed edge per spoke → Hub Firewall : auto-built
    in Phase 1.9 from "logs / DNS / authN/Z / metrics" → kind=control,
    label "Logs / DNS / AuthN-Z"
  • Hub Monitor → Hub Log Analytics : kind=control
```

Layout (Phase 2) will compute equal `max_zone_height` and
align all three zone tops at `y = 80`.

**Accents (only when opted in):**

- `Internet icon` checked → adds `"internet"` to `scene.accents`;
  Phase 2 Step D places it at the leftmost column above the zones
  row and connects via dashed `DNS Lookup` / `Authentication` edges.
- `Resource Group icon` checked → `"resource_group"` accent; small
  36×36 glyph at the bottom-left.
- `Region / subscription wireframe` checked → `"wireframe"` accent;
  outer Layer A rectangle (`fill: wireframe`) wraps all zones plus
  accents, with the region/subscription name as a floated title.

Why bundle the dashed cross-zone edges: a hub-and-spoke commonly
has 3-6 dashed edges per spoke (logs, DNS, auth, metrics, audit,
diagnostics). Drawing each individually creates a tangled web in
the gap between zones; Phase 1.9 auto-bundles them into ONE dashed
edge per spoke labeled `Logs / DNS / AuthN-Z` which reads cleaner
and conveys the same information.

### N-tier web app (single VNet, no scope words)

Horizontal gray zone rectangles for each tier:

```
scene.zones = [
  { id: "ZI", label: "Ingress",       fill: "soft_gray" },
  { id: "ZC", label: "Compute",       fill: "soft_gray" },
  { id: "ZD", label: "Data",          fill: "soft_gray" },
  { id: "ZO", label: "Observability", fill: "soft_gray" },
]
scene.orientation = "stacked"
```

Icons placed inside each zone with `node.zone` set. Edges between
icons follow the standard data-plane / control-plane style table.

### Bidirectional patterns

Set `edge.bidirectional = true` (and any `kind`; `peering` is
canonical) when modelling:

- VNet peering (Hub ↔ Spoke A, Hub ↔ Spoke B)
- Two-way replication (geo-paired SQL, Cosmos DB multi-region writes)
- mTLS service-mesh links (App A ↔ App B)
- ExpressRoute / VPN tunnels (on-prem ↔ Azure)

These render with classic arrowheads on both ends in the data-plane
blue palette.
