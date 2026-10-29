#!/usr/bin/env python3
"""Compile a NEWS report to one Letter page: render.py report.json out.pdf."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
from string import Template
import subprocess
import sys
import tempfile
from zoneinfo import ZoneInfo

from assets import HERE, STYLE, data_url, icon, styles
from editorial import automated_bottlenecks, blockers, bottlenecks, read_notes, removable, shipped
from presentation import focus, gauge, metric_row, numeric, progress_row, shown, state_bar, text, trend


def page_count(pdf):
    data = pdf.read_bytes()
    if not data.startswith(b"%PDF-") or b"%%EOF" not in data:
        raise RuntimeError("Chromium did not produce a complete PDF")
    # Chromium's print backend emits uncompressed page dictionaries, not object streams.
    count = len(re.findall(rb"/Type\s*/Page\b", data))
    if not count:
        raise RuntimeError("Cannot determine Chromium PDF page count")
    return count


def find_chromium():
    for name in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable"):
        if path := shutil.which(name):
            return path
    raise RuntimeError("Chromium is required to compile a newsletter PDF; install chromium or google-chrome")


def html(report, timezone_name=None, notes=None):
    end = datetime.fromisoformat(report["window_end"].replace("Z", "+00:00"))
    end = end.astimezone(ZoneInfo(timezone_name)) if timezone_name else end.astimezone()
    outcomes, program = report.get("outcomes", {}), report.get("program", {})
    share = outcomes.get("feature_share", {})
    editorial = {**report.get("editorial", {}), **(notes or {})}
    lanes = program.get("lanes", {})
    ordered = sorted(lanes.items(), key=lambda r: (-(numeric(r[1].get("done_in_window")) or 0), r[0])) if isinstance(lanes, dict) else []
    patterns = report.get("meta_patterns", {})
    themes = sorted(patterns.get("themes", {}).items(), key=lambda r: -(numeric(r[1]) or 0))
    pattern_html = ''.join(removable('<p>' + text(k) + ' · ' + shown(v) + '</p>', "patterns", 10) for k, v in themes[:3])
    notes_html = ''.join(removable('<p>' + text(p) + '</p>', "notes", 60) for p in editorial.get("notes", []))
    merged = outcomes.get("merged")
    fields = dict(styles=styles(), logo=data_url(STYLE / "assets/aiur-logo.png", "image/png"),
                  date=text(end.strftime("%A %d %B %Y")), window_end=text(end.strftime("%H:%M %Z")),
                  gauge=gauge(share.get("percent")), feature_count=shown(share.get("feature")), merged=shown(merged),
                  trend=trend(share.get("trend_pp")), focus=focus(report.get("allocation", {})), hand=icon("hand"),
                  blocker_count=str(len(editorial["blockers"])) if "blockers" in editorial else "?",
                  blockers=blockers(editorial.get("blockers")), program=progress_row("Whole program", program, True),
                  states=state_bar(program),
                  lanes=''.join(removable(progress_row(k.removeprefix("feature:").removeprefix("build-lane:"), v), "lanes", 20)
                                for k, v in ordered[:12]) if isinstance(lanes, dict) else shown(None),
                  funnel=''.join(metric_row(label, outcomes.get(key), merged) for label, key in
                                 (("Merged", "merged"), ("Live", "live"), ("Verified", "finished_verified"))),
                  scope=''.join(metric_row(k.title(), program.get("scope", {}).get(k), program.get("total"))
                                for k in ("added", "removed", "reopened", "paused", "shelved")),
                  shipped=shipped(editorial.get("shipped")),
                  bottlenecks=bottlenecks(editorial.get("bottlenecks", automated_bottlenecks(report))),
                  patterns='<section class="patterns"><span class="kick">Meta patterns</span>'
                           + (pattern_html or text(patterns.get("status", "unavailable"))) + '</section>',
                  notes='<section class="notes"><span class="kick">Executor notes</span>'
                        + (notes_html or shown(None)) + '</section>',
                  sources="GitHub issues/PRs; daemon build/units; local telemetry and meta/actions (availability in report.json)", omitted='')
    document = Template((HERE / "template.html").read_text()).substitute(fields)
    omitted = max(0, len(ordered) - 12) + max(0, len(themes) - 3) + max(0, len(editorial.get("shipped", [])) - 6)
    return document.replace('</body>', trim_script(omitted) + '</body>')


def trim_script(omitted):
    # Trim whole lowest-priority items after embedded fonts load. Never clip or scale.
    return '''<script>
    document.fonts.ready.then(() => {
      let removed = OMITTED;
      const candidates = [...document.querySelectorAll('[data-trim]')]
        .map((element, index) => ({element, index}))
        .sort((a, b) => Number(a.element.dataset.trim) - Number(b.element.dataset.trim) || b.index - a.index);
      const notice = document.querySelector('.omitted');
      const update = () => { notice.textContent = removed ? `${removed} lower priority items omitted; full details in report.json.` : ''; };
      update();
      for (const {element} of candidates) {
        if (document.body.scrollHeight <= 1056 && document.body.scrollWidth <= 816) break;
        element.remove(); removed++; update();
      }
      document.body.dataset.pagesFit = String(document.body.scrollHeight <= 1056 && document.body.scrollWidth <= 816);
    });
    </script>'''.replace('OMITTED', str(omitted))


def compile_report(report, output, timezone_name=None, notes=None):
    chromium = find_chromium()
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    document = html(report, timezone_name, notes)
    with tempfile.TemporaryDirectory(prefix="newsletter-", dir=output.parent) as temporary, \
            tempfile.TemporaryDirectory(prefix="newsletter-socket-", dir="/tmp") as socket_alias:
        root = Path(temporary)
        source, pdf = root / "newsletter.html", root / "newsletter.pdf"
        runtime = root / "runtime"
        runtime.mkdir()
        # A short alias keeps Chromium Unix sockets under 108 bytes; files stay private.
        alias = Path(socket_alias) / "runtime"
        alias.symlink_to(runtime, target_is_directory=True)
        env = dict(os.environ, TMPDIR=str(alias), XDG_CONFIG_HOME=str(root / "config"),
                   XDG_CACHE_HOME=str(root / "cache"))
        source.write_text(document)
        args = [chromium, "--headless", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
                "--no-pdf-header-footer", "--no-default-browser-check", "--no-first-run",
                "--user-data-dir=" + str(root / "profile"), "--virtual-time-budget=5000",
                "--print-to-pdf=" + str(pdf), source.as_uri()]
        result = subprocess.run(args, capture_output=True, text=True, timeout=90, env=env)
        if result.returncode or not pdf.exists():
            raise RuntimeError("Chromium PDF render failed: " + result.stderr[-2000:])
        pages = page_count(pdf)
        if pages != 1:
            raise RuntimeError(f"Newsletter must be exactly 1 page; Chromium produced {pages}. Reduce executor content.")
        # Page count alone cannot detect horizontal overflow; inspect the same layout.
        dom = subprocess.run(args[:args.index("--print-to-pdf=" + str(pdf))] + ["--dump-dom", source.as_uri()],
                             capture_output=True, text=True, timeout=90, env=env)
        if dom.returncode or 'data-pages-fit="true"' not in dom.stdout:
            raise RuntimeError("Newsletter content overflows Letter bounds; reduce mandatory content")
        source.replace(output.with_suffix(".html"))
        pdf.replace(output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--timezone", help="IANA operator time zone (default: local)")
    parser.add_argument("--notes", type=Path, help="editorial JSON or plain Markdown paragraphs")
    args = parser.parse_args()
    try:
        print(compile_report(json.loads(args.report.read_text()), args.output, args.timezone, read_notes(args.notes)))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"newsletter: {error}\n")


if __name__ == "__main__":
    main()
