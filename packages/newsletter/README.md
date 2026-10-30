# Daily newsletter

A standard-library Python package for collecting real Aiur evidence, computing
NEWS metrics, and printing the approved v2 broadsheet to one US Letter PDF page.
Python 3.9+ and Chromium (or Google Chrome) must be installed. No pip install,
Node build or font network access is needed at render time. Shared style tokens,
logo and fonts come from the sibling `aiur-style` package.

From the repository root:

```sh
python3 packages/newsletter/newsletter.py build --repo owner/repo
python3 packages/newsletter/newsletter.py build --repo owner/repo --notes notes.json --timezone America/Los_Angeles
```

Outputs default to the per-repository Aiur state root:
`~/.aiur/repo/<owner>/<repo>/newsletter/<UTC-date>/report.json`,
`newsletter.html`, and `newsletter.pdf`. `--state-dir <dir>` overrides that root.
Snapshots remain at `newsletter/snapshots/<UTC-date>.json`; only the previous UTC
date is eligible as a daily baseline. Missing evidence stays `unavailable`.
Repeat `--instance <name>` to include additional configured daemon sources.

Run the stages separately:

```sh
python3 packages/newsletter/newsletter.py preprocess --repo owner/repo --notes notes.md
python3 packages/newsletter/newsletter.py compile /path/to/report.json
python3 packages/newsletter/render.py /path/to/report.json /path/to/out.pdf
```

`preprocess` collects a snapshot and computes the report. `compile` consumes an
existing report, preserving its embedded notes unless a notes file overrides
the supplied editorial fields. The renderer prints without headers/footers and
checks the actual PDF page count. Missing Chromium, overflow or failed rendering
returns nonzero; no unchecked PDF replaces a successful output.

Optional notes are Markdown paragraphs (rendered as escaped text) or JSON:

```json
{
  "notes": ["An observation that cannot be measured automatically."],
  "blockers": [{"label": "Package publication", "action": "Configure publisher"}],
  "shipped": [{"icon": "rocket", "label": "Deployment observed"}],
  "bottlenecks": [{"problem": "A constraint", "action": "Action taken", "result": "Impact not measured", "tone": "attn"}]
}
```

Notes cannot replace computed metrics. Omitted editorial lists display
`unavailable`; explicit empty lists mean none reported. Bottlenecks fall back to
linked meta/action evidence when no editorial list is supplied. The page shows
up to five blockers plus `+N more`, every unfinished lane sorted by daily movement,
six shipped items, three patterns and three bottlenecks. Supported Phosphor bold
icons are `rocket`, `lightning`, `paper-plane-tilt`, `git-branch`, `cpu`, and
`seal-check`; unknown names use `git-branch`.

Content wraps without reducing fonts. If it overflows, whole items are removed
in this order: low-ranked patterns, shipped items, bottlenecks, blockers, notes.
Unfinished lanes are balanced across both columns and never removed; completed
lanes are excluded. Paused lanes have a pill, and tracker slugs use readable
product names. Each trimmed list keeps an accurate `+N more` summary, even if every item is
hidden. A page notice also reports omitted items; the complete content stays
in `report.json`. Mandatory metrics and headings are never
clipped. If those alone cannot fit, compilation fails.

The footer distinguishes merged PRs, merges proven live on a running build,
and completed features with Executor verification. Scope events and completion
are separate. Allocation's 24-hour turn-hour context remains per machine;
a seven-day average never stands in for yesterday.

Run `python3 scripts/test-newsletter-render.py` and the other
`scripts/test-newsletter-*.py` suites. Real PDF tests explain their skip when
Chromium is absent. The [daily runner and user timer](../../website/docs-app/guide/newsletter.md) prepare automatic outputs and wake the Executor; delivery remains an Executor action.
