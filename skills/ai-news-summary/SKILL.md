---
name: ai-news-summary
description: Gather AI news from curated sources plus web search, curate a dated markdown edition, and publish it to Thurbeen/ai-news to trigger a site rebuild.
user-invocable: false
allowed-tools: WebSearch, WebFetch, Bash, Read, Write, Edit
---

## AI News Summary

Produces one dated edition of an AI-news digest and publishes it to the
`Thurbeen/ai-news` content repo. Pushing the edition triggers CI to rebuild the
static site image, which ArgoCD Image Updater then deploys.

Sourcing is **hybrid**: deterministic scripts pull candidate items from curated
feeds (Hacker News, arXiv, configured RSS), and you (the agent) enrich and verify
with `WebSearch`/`WebFetch` before curating and writing the summary.

**Required env vars:** `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`.
**Optional env vars:** `EDITION` (`morning`|`evening`; otherwise inferred from the
hour in Europe/Paris), `AI_NEWS_REPO` (default `Thurbeen/ai-news`).

---

### Step 0 — Setup

```bash
SKILL_DIR="$(cd "$(dirname "$(readlink -f ~/.claude/skills/ai-news-summary/SKILL.md)")" && pwd)"
source "$SKILL_DIR/scripts/common.sh"
require_env GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

SETUP="$(bash "$SKILL_DIR/scripts/setup-repo.sh")"
```

Parse the JSON from `$SETUP`: `workdir`, `repo`, `date`, `edition`. Then change
into the cloned repo so config and content paths resolve correctly:

```bash
cd "<workdir>"
```

---

### Step 1 — Gather candidate items

Run from the repo root (so `.claude/config.yaml` is read):

```bash
EDITION="<edition>" NEWS_DATE="<date>" bash "$SKILL_DIR/scripts/gather-sources.sh"
```

This emits JSON `{edition, date, count, items:[{source,title,url,score,published,summary}]}`.
Some sources may be empty (a feed can be unreachable in-cluster) — that is fine.

---

### Step 2 — Enrich and verify (hybrid)

For the most significant candidate items, and to fill gaps the feeds miss:

- Use `WebSearch` with the queries in `sources.websearch_queries` (from
  `.claude/config.yaml`) to surface major releases/announcements from the last day.
- Use `WebFetch` to read and verify the top source links and corroborating
  coverage. **Note:** in-cluster egress is allow-listed — `WebFetch` to domains
  not on the allow-list will fail. Treat such failures as non-fatal and rely on
  `WebSearch` results and the feed metadata instead.

Prefer primary sources, deduplicate stories that appear across feeds, and discard
low-signal or off-topic items.

---

### Step 3 — Curate and write the edition

Select roughly **6–10** of the strongest, genuinely AI-related items. Write the
file `content/<date>-<edition>.md` (overwrite if it already exists for a re-run)
using the **Write** tool, with this frontmatter and structure:

```markdown
---
title: "AI News — <Morning|Evening> Edition"
date: <date>
edition: <edition>
sources: [hackernews, arxiv, rss, websearch]
---

## <Lead story headline>

2–4 sentence summary in your own words. Link the primary source inline.

## <Next story>

...

## Also notable

- One-line item — [source](url)
- One-line item — [source](url)
```

Guidelines: concise, neutral, link every claim, group research (arXiv) separately
from product/industry news when it reads better, and lead with the day's most
consequential story.

---

### Step 4 — Publish

```bash
bash "$SKILL_DIR/scripts/publish-edition.sh" "content/<date>-<edition>.md"
```

Parse the JSON:
- `status: "published"` → report the file and the 7-char `sha` (this becomes the
  deployed image tag).
- `status: "no_changes"` → the edition was already up to date; report that.

---

### Output

Print a short summary: edition (`<date> <edition>`), number of items included,
and either the published commit SHA or "no changes".
